/**
 * Federation — our own message log and peer sync. No external hub.
 *
 * Transport is OUTBOUND-ONLY in both directions: a node pushes its own new
 * messages to each peer and pulls each peer's new ones. A node therefore needs
 * no inbound reachability at all, which matters because NetBird in userspace
 * mode (macOS) blackholes inbound to the overlay IP while outbound works.
 */

export type FedMessage = {
  /** origin node + per-node sequence: stable across relays, so dedup is exact */
  id: string;
  node: string;
  seq: number;
  from: string;
  text: string;
  at: string;
};

export type Peer = { name: string; url: string; via?: string };

/** what a peer publishes about its panes; the shape our own /api/fed/state emits */
export type PeerMember = {
  handle: string;
  kind: string;
  where?: string;
  status?: string;
  pane: string;
  terminal?: string;
  tab?: string;
  workspace?: string;
  repo?: string;
};

import type { AuditEntry, MemberRecord } from "./wire";

export type FedConfig = {
  node: string;
  peers: Peer[];
  gossip?: boolean;
};

export class Federation {
  #messages: FedMessage[] = [];
  #seen = new Set<string>();
  #seq = 0;
  #peers: Peer[];
  health: Record<string, { ok?: boolean; lastError?: string; lastSeen?: string }> = {};
  /**
   * Nodes we have heard from but cannot reach back. A one-way link is normal
   * here (userspace-mode NetBird), and the federation should still show them.
   */
  known: Record<string, { node: string; url?: string; lastHeard: string }> = {};
  /** each peer's own roster, as that node reported it */
  peerMembers: Record<string, PeerMember[]> = {};
  peerUi: Record<string, string> = {};
  stats = { pushed: 0, pulled: 0, errors: 0, startedAt: new Date().toISOString() };

  /** what each peer reports about its own membership — read-only, for the mesh view */
  peerFederated: Record<string, MemberRecord[]> = {};
  /** kicks each peer published; adopting one is always a deliberate click here */
  peerKicks: Record<string, AuditEntry[]> = {};

  constructor(
    readonly config: FedConfig,
    readonly statePath: string,
    /**
     * The credential to present to a given peer. Membership lives in Members;
     * this class only needs to know how to stamp an outbound call.
     */
    readonly tokenFor: (node: string) => string | undefined = () => undefined,
    readonly timeoutMs = 5000,
  ) {
    this.#peers = [...config.peers];
  }

  /** Register a peer we have just completed a handshake with. */
  addPeer(name: string, url: string) {
    const existing = this.#peers.find((p) => p.name === name);
    if (existing) existing.url = url;
    else this.#peers.push({ name, url });
    this.config.peers = this.#peers.map(({ name: n, url: u }) => ({ name: n, url: u }));
  }

  get peers() {
    return this.#peers;
  }

  /**
   * Join a hub by address, the way you join a Discord server: probe it, learn
   * its node name from its own mouth, and adopt it. Gossip then spreads the rest
   * of the federation to us on the next pull.
   */
  async join(url: string) {
    const clean = url.trim().replace(/\/+$/, "");
    const res = await fetch(`${clean}/api/fed/state`, { signal: AbortSignal.timeout(this.timeoutMs) });
    if (!res.ok) throw new Error(`${clean} answered ${res.status}`);
    const state = (await res.json()) as { node?: string };
    if (!state.node) throw new Error(`${clean} is not a federation node`);
    if (state.node === this.config.node) throw new Error("that address is this node");

    const existing = this.#peers.find((p) => p.name === state.node);
    if (existing) {
      existing.url = clean;
    } else {
      this.#peers.push({ name: state.node, url: clean });
    }
    this.config.peers = this.#peers.map(({ name, url: u }) => ({ name, url: u }));
    await this.pullAll();
    return { node: state.node, url: clean };
  }

  leave(name: string) {
    this.#peers = this.#peers.filter((p) => p.name !== name);
    this.config.peers = this.#peers.map(({ name: n, url }) => ({ name: n, url }));
    delete this.peerMembers[name];
    delete this.peerFederated[name];
    delete this.peerKicks[name];
    delete this.health[name];
  }

  get messages() {
    return this.#messages;
  }

  async load() {
    try {
      const saved = await Bun.file(this.statePath).json();
      this.#messages = saved.messages ?? [];
      this.#seq = saved.seq ?? 0;
      for (const m of this.#messages) this.#seen.add(m.id);
    } catch {
      // first run
    }
  }

  async save() {
    await Bun.write(this.statePath, JSON.stringify({ seq: this.#seq, messages: this.#messages.slice(-500) }));
  }

  /** Record a message this node originated, and hand it to every peer. */
  async post(from: string, text: string) {
    const msg: FedMessage = {
      id: `${this.config.node}:${++this.#seq}`,
      node: this.config.node,
      seq: this.#seq,
      from,
      text,
      at: new Date().toISOString(),
    };
    this.#accept(msg);
    await this.save();
    void this.pushAll();
    return msg;
  }

  #accept(msg: FedMessage) {
    if (this.#seen.has(msg.id)) return false;
    this.#seen.add(msg.id);
    this.#messages.push(msg);
    this.#messages = this.#messages.slice(-500);
    return true;
  }

  /** How other nodes should reach us, when we know. */
  advertised?: string;

  /** Messages a peer hands us. Exact dedup by origin id, so no echo storms. */
  ingest(incoming: FedMessage[], from?: { node?: string; url?: string }) {
    if (from?.node && from.node !== this.config.node) {
      this.known[from.node] = { node: from.node, url: from.url, lastHeard: new Date().toISOString() };
    }
    let added = 0;
    for (const m of incoming) if (m?.id && this.#accept(m)) added++;
    for (const m of incoming) {
      if (m?.node && m.node !== this.config.node && !this.known[m.node])
        this.known[m.node] = { node: m.node, lastHeard: new Date().toISOString() };
    }
    if (added) void this.save();
    return added;
  }

  #fetch(peer: Peer, path: string, init: RequestInit = {}) {
    // one place stamps the credential, so no call site can forget to
    const token = this.tokenFor(peer.name);
    return fetch(`${peer.url}${path}`, {
      ...init,
      signal: AbortSignal.timeout(this.timeoutMs),
      headers: {
        "content-type": "application/json",
        ...(token ? { "x-fed-token": token } : {}),
        ...(init.headers ?? {}),
      },
    });
  }

  async pushAll() {
    const mine = this.#messages.filter((m) => m.node === this.config.node);
    if (!mine.length) return;
    await Promise.all(
      this.#peers.map(async (peer) => {
        try {
          const res = await this.#fetch(peer, "/api/fed/ingest", {
            method: "POST",
            // introduce ourselves, so a peer that cannot reach back still knows we exist
            body: JSON.stringify({ messages: mine.slice(-100), from: { node: this.config.node, url: this.advertised } }),
          });
          if (!res.ok) throw new Error(`${res.status}`);
          this.stats.pushed++;
          this.health[peer.name] = { ok: true, lastSeen: new Date().toISOString() };
        } catch (err) {
          this.stats.errors++;
          this.health[peer.name] = { ok: false, lastError: String(err) };
        }
      }),
    );
  }

  /** Pull is what makes an unreachable node still work: we fetch, it never has to reach us. */
  async pullAll() {
    await Promise.all(
      this.#peers.map(async (peer) => {
        try {
          const res = await this.#fetch(peer, "/api/fed/state");
          if (!res.ok) throw new Error(`${res.status}`);
          const state = (await res.json()) as {
            node?: string;
            messages?: FedMessage[];
            members?: PeerMember[];
            peers?: Peer[];
            federated?: MemberRecord[];
            kicks?: AuditEntry[];
          };
          const added = this.ingest(state.messages ?? []);
          this.stats.pulled += added;
          this.peerMembers[peer.name] = state.members ?? [];
          this.peerFederated[peer.name] = state.federated ?? [];
          this.peerKicks[peer.name] = state.kicks ?? [];
          this.peerUi[peer.name] = peer.url;
          this.health[peer.name] = { ok: true, lastSeen: new Date().toISOString() };

          if (this.config.gossip) {
            for (const cand of state.peers ?? []) {
              const known = cand.name === this.config.node || this.#peers.some((p) => p.name === cand.name);
              if (!known && cand.url) this.#peers.push({ ...cand, via: peer.name });
            }
          }
        } catch (err) {
          this.stats.errors++;
          this.health[peer.name] = { ok: false, lastError: String(err) };
        }
      }),
    );
  }
}

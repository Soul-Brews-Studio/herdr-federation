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

export type PeerHealth = {
  ok?: boolean;
  lastError?: string;
  lastErrorAt?: string;
  lastSeen?: string;
  lastOkAt?: string;
  /** failed attempts since the last success — 0 means the link is fine right now */
  consecutive: number;
  /** the address that last completed a sync; evidence, versus an advertised claim */
  lastOkUrl?: string;
};

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
  /**
   * Per-peer health, and the only honest answer to "is this link working NOW".
   *
   * `consecutive` is what a UI should read: lifetime totals cannot tell an
   * outage an hour ago from one happening this second. Measured: m5 sat at
   * `errors 1676` for an hour after white came back, beside a peer marked ok.
   */
  health: Record<string, PeerHealth> = {};
  /**
   * Nodes we have heard from but cannot reach back. A one-way link is normal
   * here (userspace-mode NetBird), and the federation should still show them.
   */
  known: Record<string, { node: string; url?: string; lastHeard: string }> = {};
  /** each peer's own roster, as that node reported it */
  peerMembers: Record<string, PeerMember[]> = {};
  peerUi: Record<string, string> = {};
  /**
   * Lifetime totals. `pushed` and `pullOk` count REQUESTS; `pulled` counts
   * MESSAGES ingested, which is a different unit and is legitimately 0 whenever
   * peers have nothing new. Printing "pushed 1143 · pulled 0" side by side read
   * as a one-way failure when nothing was wrong — hence the separate pullOk.
   */
  stats = { pushed: 0, pushErrors: 0, pullOk: 0, pullErrors: 0, pulled: 0, errors: 0, startedAt: new Date().toISOString() };

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

  /**
   * Register a peer we have just completed a handshake with.
   *
   * A node advertises ONE address, and that is not always the best one we have.
   * m5 advertises its NetBird IP, but m5 runs NetBird in userspace mode, so
   * inbound to that IP is blackholed — white can only reach m5 over the LAN.
   * Taking the advertised address unconditionally therefore replaced white's
   * working URL with an unreachable one and killed a link that was fine.
   * So: an address we already have and that is currently healthy wins.
   */
  addPeer(name: string, url: string) {
    const existing = this.#peers.find((p) => p.name === name);
    if (existing) {
      // NEVER trade an address that has worked for one that merely claims to.
      //
      // Two earlier rules were both wrong. "replace unless currently ok" broke
      // right after a restart, when health is undefined. "replace when KNOWN
      // BAD" broke too, and worse: a link is known-bad for reasons that have
      // nothing to do with the address — m5 kicked white, so white's pulls 401'd,
      // so white took m5's advertised NetBird IP and replaced the LAN address
      // that had been working. m5 runs NetBird in userspace mode, which
      // blackholes inbound to that IP, so the "repair" made the link permanently
      // unreachable. Measured twice.
      //
      // An address that has ever completed a sync is evidence; an advertised one
      // is a claim. Evidence wins, and a node only ever advertises ONE address
      // while a peer may be the only one who knows the reachable one.
      const proven = this.health[name]?.lastOkUrl;
      if (!existing.url) existing.url = url;
      else if (!proven) existing.url = url;
      else if (existing.url !== proven) existing.url = proven;
    } else this.#peers.push({ name, url });
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

  /**
   * Record one attempt. Merging matters: push and pull run in the same cycle, so
   * assigning a whole record let whichever finished last erase the other's
   * verdict — a link failing one way flapped green every other tick.
   */
  #mark(peer: string, ok: boolean, error?: string) {
    const now = new Date().toISOString();
    const prev = this.health[peer] ?? { consecutive: 0 };
    this.health[peer] = ok
      ? { ...prev, ok: true, lastSeen: now, lastOkAt: now, consecutive: 0, lastError: undefined, lastErrorAt: undefined,
          lastOkUrl: this.#peers.find((p) => p.name === peer)?.url ?? prev.lastOkUrl }
      : { ...prev, ok: false, lastError: error, lastErrorAt: now, consecutive: (prev.consecutive ?? 0) + 1 };
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
          this.#mark(peer.name, true);
        } catch (err) {
          this.stats.pushErrors++;
          this.stats.errors++;
          this.#mark(peer.name, false, String(err));
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
          this.stats.pullOk++;
          this.stats.pulled += added;
          this.peerMembers[peer.name] = state.members ?? [];
          this.peerFederated[peer.name] = state.federated ?? [];
          this.peerKicks[peer.name] = state.kicks ?? [];
          this.peerUi[peer.name] = peer.url;
          this.#mark(peer.name, true);

          // Gossip LEARNS OF nodes; it no longer adopts them.
          //
          // Adopting predates membership and is now actively wrong. A peer we
          // hold no token for cannot be synced with — every push and pull to it
          // 401s or times out — so adoption only manufactures failing requests
          // every cycle. Worse, it silently undoes a kick: measured on a six-node
          // demo, a kicked node was gone from members and from peers.json and
          // back in the in-memory peer list within one cycle, costing a failed
          // request every 2s and drawing a phantom edge holding nothing.
          //
          // `known` is exactly the right home for "we have heard of this node":
          // the console already renders it as "heard from, not joined" with a
          // join button, which is the deliberate act adoption was pretending to be.
          if (this.config.gossip) {
            for (const cand of state.peers ?? []) {
              if (cand.name === this.config.node) continue;
              if (this.#peers.some((p) => p.name === cand.name)) continue;
              this.known[cand.name] = { node: cand.name, url: cand.url, lastHeard: new Date().toISOString() };
            }
          }
        } catch (err) {
          this.stats.pullErrors++;
          this.stats.errors++;
          this.#mark(peer.name, false, String(err));
        }
      }),
    );
  }
}

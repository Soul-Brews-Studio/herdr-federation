/**
 * The federation node: one service, one dependency — the Herdr socket.
 *
 * Serves the React console, streams panes over our own WebSocket (polling
 * `pane.read` and shipping only changed revisions), sends input back through
 * `pane.send_text` / `pane.send_keys`, and syncs messages with peer nodes.
 */

import { existsSync } from "node:fs";
import { join } from "node:path";
import * as herdr from "./herdr";
import type { Pane, Tab, Workspace } from "./protocol";
import type {
  AdminState, AdoptRequest, AuditEntry, AuditStep, BroadcastRequest, BroadcastResult, CallsResponse,
  CreateInviteRequest, CreateInviteResponse, ErrorResponse, FedRedeemRequest, FedRedeemResponse,
  FedHeyRequest, FedPaneRelayRequest, FedPaneRequest, FedPaneResponse, FedRelayRequest, FedState,
  HeyRequest, HeyResponse, IngestRequest, IngestResponse,
  Invite, InvitePreview, RelayedPeer,
  InvitesResponse, JoinRequest, JoinResponse, KickRequest, KickResponse, LeaveRequest,
  LeaveResponse, Member, PaneClientMessage, PaneServerMessage, RedeemRequest, RedeemResponse,
  StatusResponse, Topology, UiTab, UiWorkspace,
} from "./wire";
import { Federation, type FedConfig, type FedMessage } from "./federation";
import { NodeIdentity, secret } from "./identity";
import { Members, RedeemError, redeemMessage } from "./members";

// import.meta.dir, not new URL().pathname — the latter percent-encodes the ψ in the repo path
const ROOT = join(import.meta.dir, "..");
const CONFIG_PATH = process.env.FED_CONFIG ?? join(ROOT, "peers.json");
const STATE_PATH = process.env.FED_STATE ?? join(ROOT, ".fed-state.json");
const IDENTITY_PATH = process.env.FED_IDENTITY ?? join(ROOT, ".fed-identity.json");
const MEMBERS_PATH = process.env.FED_MEMBERS ?? join(ROOT, ".fed-members.json");
const DIST = join(ROOT, "web", "dist");
const PORT = Number(process.env.FED_PORT ?? 6750);
const HOST = process.env.FED_HOST ?? "127.0.0.1";
const SYNC_MS = Number(process.env.FED_SYNC_MS ?? 2000);
const PANE_MS = Number(process.env.FED_PANE_MS ?? 300);
/**
 * Peers that predate tokens still work while this is on. It is on by default
 * for exactly one release so an already-federated pair does not go dark on
 * deploy; the admin page says so loudly on every screen until it is off.
 */
const ALLOW_LEGACY = (process.env.FED_ALLOW_LEGACY ?? "1") !== "0";

const config: FedConfig = await Bun.file(CONFIG_PATH).json();

/** How peers reach us. 0.0.0.0 means "bound everywhere", which is not an address. */
function publicBase(): string | null {
  if (process.env.FED_ADVERTISE) return `http://${process.env.FED_ADVERTISE}:${PORT}`;
  return HOST === "127.0.0.1" || HOST === "0.0.0.0" || HOST === "localhost" ? null : `http://${HOST}:${PORT}`;
}

const ident = await NodeIdentity.open(config.node, IDENTITY_PATH);
const fedMembers = new Members(config.node, MEMBERS_PATH, publicBase, ALLOW_LEGACY);
await fedMembers.load();

const fed = new Federation(config, STATE_PATH, (node) => fedMembers.tokenFor(node));
fed.advertised = publicBase() ?? undefined;
await fed.load();

// peers configured before tokens existed: show them, flagged, rather than hide them
for (const p of fed.peers) fedMembers.adoptLegacy(p.name, p.url);

let members: Member[] = [];
/** workspace + tab topology, so the console can show what herdr itself shows */
let topology: Topology = { workspaces: [], tabs: [] };

async function refreshMembers() {
  try {
    const snap = await herdr.snapshot();
    topology = {
      workspaces: (snap.workspaces ?? []).map((w: Workspace): UiWorkspace => ({
        id: w.workspace_id,
        label: w.label,
        number: w.number,
        status: w.agent_status,
        paneCount: w.pane_count,
        repo: w.worktree?.repo_name,
        checkout: w.worktree?.checkout_path,
        linkedWorktree: w.worktree?.is_linked_worktree,
      })),
      tabs: (snap.tabs ?? []).map((t: Tab): UiTab => ({
        id: t.tab_id,
        workspace: t.workspace_id,
        label: t.label,
        number: t.number,
        status: t.agent_status,
        paneCount: t.pane_count,
      })),
    };
    const workspaces = new Map<string, Workspace>((snap.workspaces ?? []).map((w: Workspace) => [w.workspace_id, w]));

    members = (snap.panes ?? []).map((p: Pane): Member => {
      const ws = p.workspace_id ? workspaces.get(p.workspace_id) : undefined;
      return {
        handle: p.agent_name ?? p.label ?? p.terminal_title_stripped ?? p.pane_id,
        kind: p.agent ?? "shell",
        where: p.cwd,
        status: p.agent_status,
        pane: p.pane_id,
        terminal: p.terminal_id,
        focused: p.focused,
        revision: p.revision,
        scrollback: p.scroll?.max_offset_from_bottom,
        rows: p.scroll?.viewport_rows,
        tab: p.tab_id,
        workspace: p.workspace_id,
        workspaceLabel: ws?.label,
        repo: ws?.worktree?.repo_name,
      };
    });
  } catch {
    members = [];
  }
}

const json = <T,>(body: T, status = 200) => Response.json(body, { status });

const saveConfig = () =>
  Bun.write(CONFIG_PATH, JSON.stringify({ ...config, peers: fed.peers.map(({ name, url }) => ({ name, url })) }, null, 2));

/** What to hand someone so they can join this node — Discord's invite, minus the server. */
function invite(): Invite {
  const base = publicBase();
  return {
    node: config.node,
    session: process.env.HERDR_SESSION ?? null,
    socket: herdr.SOCKET_PATH,
    url: base,
    hint: base ? null : "set FED_ADVERTISE to the address peers should use, or this node cannot issue a working invite",
  };
}

/**
 * Federation endpoints are members-only. A kicked node fails here on its very
 * next call, which is the difference between a kick and merely looking away.
 */
function member(req: Request) {
  const found = fedMembers.authenticate(req.headers.get("x-fed-token"));
  if (found) return { ok: true as const, node: found.node };
  if (ALLOW_LEGACY) return { ok: true as const, node: "(legacy, unverified)" };
  return { ok: false as const, node: "" };
}

const unauthorized = () => json<ErrorResponse>({ error: "not a member of this node — redeem an invite" }, 401);

/** Only the invite preview is readable cross-origin; nothing else here is. */
function cors(res: Response) {
  res.headers.set("access-control-allow-origin", "*");
  return res;
}

/** Panes are addressed as `wD:p4`; anything else is not ours to open. */
const validPane = (id: string) => /^[A-Za-z0-9_:-]+$/.test(id);

type PaneSocket = { paneId: string; format: "text" | "ansi"; timer?: ReturnType<typeof setInterval>; last?: string; push?: () => Promise<void> };

/** Who is watching what, so a send can refresh those viewers at once. */
const watchers = new Map<string, Set<{ data: PaneSocket }>>();

/** After we type into a pane, push a frame now instead of waiting for the next tick. */
/**
 * Deliver text to one of OUR panes by pane id or handle. The one local delivery
 * path, so the console endpoint, the peer endpoint and the broadcast fan-out
 * cannot drift in what "to" means.
 */
async function deliverLocal(to: string, text: string) {
  const target = members.find((m) => m.pane === to || m.handle === to);
  if (!target) throw new Error(`no agent ${to} on ${config.node}`);
  await herdr.prompt(target.pane, text);
  nudge(target.pane);
  return target;
}

/**
 * Everything we know about our DIRECT peers, for a spoke that asked. `except`
 * is the asker: it must not be handed its own roster back as a relayed node.
 * Only rosters that arrived on a successful pull are republished — a peer we
 * never reached has nothing to relay, and an empty entry would draw a ghost.
 */
function relayedFor(except: string): Record<string, RelayedPeer> {
  const out: Record<string, RelayedPeer> = {};
  for (const p of fed.peers) {
    if (p.name === except || p.name === config.node) continue;
    const h = fed.health[p.name];
    if (!h?.lastOkAt) continue;
    out[p.name] = {
      url: p.url,
      members: fed.peerMembers[p.name] ?? [],
      ok: h.ok,
      lastOkAt: h.lastOkAt,
      consecutive: h.consecutive ?? 0,
    };
  }
  return out;
}

/** Every roster we can see — our direct peers' plus what hubs relayed — in one map. */
function allPeerMembers(): Record<string, Member[]> {
  const out: Record<string, Member[]> = { ...fed.peerMembers };
  for (const [n, r] of Object.entries(fed.relayed)) if (!(n in out)) out[n] = r.members;
  return out;
}

/** Where to send an action for a node: itself if direct, its hub if relayed. */
function allPeerUi(): Record<string, string> {
  const out: Record<string, string> = { ...fed.peerUi };
  for (const [n, r] of Object.entries(fed.relayed)) if (!(n in out)) out[n] = fed.peerUi[r.via] ?? fed.peer(r.via)?.url ?? "";
  return out;
}

/** Relayed nodes as PeerView rows. `via` set, health = the hub's link to them. */
function relayedViews() {
  return Object.entries(fed.relayed).map(([name, r]) => ({
    name,
    url: fed.peerUi[r.via] ?? fed.peer(r.via)?.url ?? "",
    via: r.via,
    ok: r.ok,
    lastOkAt: r.lastOkAt,
    consecutive: r.consecutive ?? 0,
  }));
}

function nudge(paneId: string) {
  for (const ws of watchers.get(paneId) ?? []) {
    ws.data.last = undefined;
    void ws.data.push?.();
  }
}

const server = Bun.serve<PaneSocket, {}>({
  port: PORT,
  hostname: HOST,
  idleTimeout: 120,

  async fetch(req, srv) {
    const url = new URL(req.url);
    const path = url.pathname;

    // ── live pane stream ────────────────────────────────────────────
    if (path.startsWith("/ws/pane/")) {
      const paneId = decodeURIComponent(path.slice("/ws/pane/".length));
      if (!validPane(paneId)) return new Response("bad pane", { status: 400 });
      const format = url.searchParams.get("format") === "ansi" ? "ansi" : "text";
      if (srv.upgrade(req, { data: { paneId, format } })) return undefined as unknown as Response;
      return new Response("expected a websocket", { status: 426 });
    }

    // ── federation (peer to peer, no hub) ───────────────────────────
    if (path === "/api/fed/state") {
      const who = member(req);
      if (!who.ok) return unauthorized();
      return json<FedState>({
        node: config.node,
        identity: ident.identity,
        messages: fed.messages,
        members,
        peers: fed.peers.map((p) => ({ name: p.name, url: p.url, via: p.via })),
        federated: fedMembers.members,
        kicks: fedMembers.publishedKicks,
        relayed: relayedFor(who.node),
      });
    }
    if (path === "/api/fed/ingest" && req.method === "POST") {
      if (!member(req).ok) return unauthorized();
      const body = (await req.json()) as IngestRequest;
      return json<IngestResponse>({ added: fed.ingest(body.messages ?? [], body.from), node: config.node });
    }
    /**
     * A peer delivering to one of OUR panes. Member-gated, unlike /api/hey: this
     * is the path peers and hubs use, so it needs the token the console path
     * still lacks.
     */
    if (path === "/api/fed/hey" && req.method === "POST") {
      if (!member(req).ok) return unauthorized();
      const { to, text } = (await req.json()) as FedHeyRequest;
      if (!to || !text?.trim()) return json<ErrorResponse>({ error: "need to and text" }, 400);
      try {
        const t = await deliverLocal(to, text.trim());
        return json<HeyResponse>({ delivered: "pane", to: t.handle, pane: t.pane });
      } catch (err) {
        return json<ErrorResponse>({ error: String(err).replace(/^Error:\s*/, "") }, 404);
      }
    }
    /**
     * A peer reading one of OUR panes. Same gate as /api/fed/hey, and the same
     * `source: "visible"` rule the console path uses — `recent` is serviced by
     * driving the pane's own mouse-scroll, so a background poll would scroll the
     * operator's real terminal. A read that moves the thing being read is not a
     * read, so it is not configurable here either.
     */
    if (path === "/api/fed/pane" && req.method === "POST") {
      if (!member(req).ok) return unauthorized();
      const { pane, lines } = (await req.json()) as FedPaneRequest;
      if (!pane || !validPane(pane)) return json<ErrorResponse>({ error: "bad pane id" }, 400);
      try {
        const n = Math.min(Math.max(Number(lines) || 40, 1), 400);
        const read = await herdr.readPane(pane, { source: "visible", lines: n });
        return json<FedPaneResponse>({ node: config.node, pane, text: typeof read === "string" ? read : String((read as { text?: string })?.text ?? ""), lines: n });
      } catch (err) {
        return json<ErrorResponse>({ error: String(err).replace(/^Error:\s*/, "") }, 502);
      }
    }
    /** A spoke asking us, its hub, to read a pane on one of OUR direct peers. One hop. */
    if (path === "/api/fed/pane-relay" && req.method === "POST") {
      if (!member(req).ok) return unauthorized();
      const { node, pane, lines } = (await req.json()) as FedPaneRelayRequest;
      if (!node || !pane) return json<ErrorResponse>({ error: "need node and pane" }, 400);
      if (!fed.peer(node)) return json<ErrorResponse>({ error: `${node} is not a direct peer of ${config.node} — no route` }, 404);
      try {
        const res = await fed.call(node, "/api/fed/pane", { method: "POST", body: JSON.stringify({ pane, lines }) });
        const out = await res.json();
        if (!res.ok || out.error) return json<ErrorResponse>({ error: out.error ?? `${node} answered ${res.status}` }, res.ok ? 502 : res.status);
        return json<FedPaneResponse>(out);
      } catch (err) {
        return json<ErrorResponse>({ error: String(err).replace(/^Error:\s*/, "") }, 502);
      }
    }
    /**
     * The console asking THIS node to read a pane anywhere in the federation.
     * Ungated like the rest of the console surface; it routes by node, so a
     * client never has to know whether a node is direct or behind a hub.
     */
    if (path === "/api/fleet/pane" && req.method === "POST") {
      const { node, pane, lines } = (await req.json()) as FedPaneRelayRequest;
      if (!node || !pane) return json<ErrorResponse>({ error: "need node and pane" }, 400);
      try {
        if (node === config.node) {
          if (!validPane(pane)) return json<ErrorResponse>({ error: "bad pane id" }, 400);
          const n = Math.min(Math.max(Number(lines) || 40, 1), 400);
          const read = await herdr.readPane(pane, { source: "visible", lines: n });
          return json<FedPaneResponse>({ node, pane, text: typeof read === "string" ? read : String((read as { text?: string })?.text ?? ""), lines: n });
        }
        let res: Response;
        if (fed.peer(node)) {
          res = await fed.call(node, "/api/fed/pane", { method: "POST", body: JSON.stringify({ pane, lines }) });
        } else if (fed.relayed[node]) {
          res = await fed.call(fed.relayed[node].via, "/api/fed/pane-relay", { method: "POST", body: JSON.stringify({ node, pane, lines }) });
        } else {
          return json<ErrorResponse>({ error: `no route to ${node} — not a peer, and no hub relays it` }, 404);
        }
        const out = await res.json();
        if (!res.ok || out.error) return json<ErrorResponse>({ error: out.error ?? `${node} answered ${res.status}` }, res.ok ? 502 : res.status);
        return json<FedPaneResponse>(out);
      } catch (err) {
        return json<ErrorResponse>({ error: String(err).replace(/^Error:\s*/, "") }, 502);
      }
    }
    /**
     * A spoke asking us, its hub, to forward to one of OUR direct peers. One hop
     * only: if the target is not our direct peer we say so rather than relay a
     * relay, so a message cannot wander a ring of hubs.
     */
    if (path === "/api/fed/relay" && req.method === "POST") {
      const who = member(req);
      if (!who.ok) return unauthorized();
      const { node, to, text } = (await req.json()) as FedRelayRequest;
      if (!node || !to || !text?.trim()) return json<ErrorResponse>({ error: "need node, to and text" }, 400);
      if (!fed.peer(node)) return json<ErrorResponse>({ error: `${node} is not a direct peer of ${config.node} — no route` }, 404);
      try {
        const res = await fed.call(node, "/api/fed/hey", { method: "POST", body: JSON.stringify({ to, text: text.trim() }) });
        const out = await res.json();
        if (!res.ok || out.error) return json<ErrorResponse>({ error: out.error ?? `${node} answered ${res.status}` }, res.ok ? 502 : res.status);
        return json<HeyResponse>(out);
      } catch (err) {
        return json<ErrorResponse>({ error: String(err).replace(/^Error:\s*/, "") }, 502);
      }
    }

    /**
     * Someone presents an invite. Deliberately the one federation endpoint with
     * no token check — the invite secret IS the credential, and it is spent here.
     */
    if (path === "/api/fed/redeem" && req.method === "POST") {
      const body = (await req.json()) as FedRedeemRequest;
      try {
        const { memberToken } = fedMembers.redeem(body);
        fed.addPeer(body.node, body.url ?? "");
        await saveConfig();
        void fed.pullAll();
        return json<FedRedeemResponse>({
          node: config.node,
          pubkey: ident.pubkey,
          url: publicBase() ?? undefined,
          memberToken,
        });
      } catch (err) {
        const code = err instanceof RedeemError ? err.code : "error";
        return json<ErrorResponse>({ error: `${code}: ${(err as Error).message}` }, code === "banned" ? 403 : 400);
      }
    }

    if (path === "/api/invite") return json(invite());

    /** every socket transaction this node has made, with its CLI equivalent */
    if (path === "/api/calls")
      return json<CallsResponse>({ calls: herdr.calls().slice(0, Number(url.searchParams.get("limit") ?? 80)) });

    if (path === "/api/peers/join" && req.method === "POST") {
      // the pre-invite way in. Only reachable while legacy peers are tolerated.
      if (!ALLOW_LEGACY) return json<ErrorResponse>({ error: "this node only accepts invite links" }, 403);
      const { url: peerUrl } = (await req.json()) as JoinRequest;
      if (!peerUrl?.trim()) return json({ error: "no address" }, 400);
      try {
        const joined = await fed.join(peerUrl);
        await saveConfig();
        return json<JoinResponse>({ joined });
      } catch (err) {
        return json({ error: String(err).replace(/^Error:\s*/, "") }, 400);
      }
    }

    if (path === "/api/peers/leave" && req.method === "POST") {
      const { name } = (await req.json()) as LeaveRequest;
      if (!name) return json<ErrorResponse>({ error: "no peer" }, 400);
      fed.leave(name);
      await saveConfig();
      return json<LeaveResponse>({ left: name });
    }

    // ── membership: invites, members, bans, audit ───────────────────
    if (path === "/api/invites" && req.method === "POST") {
      const body = (await req.json().catch(() => ({}))) as CreateInviteRequest;
      return json<CreateInviteResponse>({ invite: fedMembers.createInvite(body) });
    }
    if (path === "/api/invites" && req.method === "GET") return json<InvitesResponse>({ invites: fedMembers.invites });

    if (path.startsWith("/api/invites/") && req.method === "DELETE") {
      const revoked = fedMembers.revokeInvite(path.slice("/api/invites/".length));
      if (!revoked) return json<ErrorResponse>({ error: "no such invite" }, 404);
      await saveConfig();
      return json({ invite: revoked });
    }

    /**
     * What the join landing page may show before anyone commits. The secret in
     * the URL is the ticket, so this is readable cross-origin: the joiner's own
     * console has to render it, and whoever holds the token already holds it.
     */
    if (path.startsWith("/api/invite-preview/")) {
      const found = fedMembers.preview(decodeURIComponent(path.slice("/api/invite-preview/".length)));
      if (!found) return cors(json<ErrorResponse>({ error: "that invite does not exist on this node" }, 404));
      return cors(json<InvitePreview>({
        node: config.node,
        fingerprint: ident.identity.fingerprint,
        url: publicBase(),
        expiresAt: found.invite.expiresAt,
        createdBy: found.invite.createdBy,
        note: found.invite.note,
        status: found.status,
        members: fedMembers.members.length,
      }));
    }

    /** Our own console telling this node to go redeem an invite somewhere. */
    if (path === "/api/peers/redeem" && req.method === "POST") {
      const { from, token } = (await req.json()) as RedeemRequest;
      if (!from?.trim() || !token?.trim()) return json<ErrorResponse>({ error: "need both an address and an invite token" }, 400);
      const target = from.trim().replace(/\/+$/, "");
      const offerToken = secret();
      const at = new Date().toISOString();
      const body: FedRedeemRequest = {
        token: token.trim(),
        node: config.node,
        pubkey: ident.pubkey,
        url: publicBase() ?? undefined,
        offerToken,
        at,
        sig: ident.sign(redeemMessage({ token: token.trim(), node: config.node, at })),
      };
      const steps: AuditStep[] = [
        { n: 1, label: "read the invite link", ok: true, detail: `${target} · token ${token.trim().slice(0, 6)}…` },
        { n: 2, label: "mint the token we will issue them", ok: true, detail: "one round trip authenticates both directions" },
        { n: 3, label: "sign the request with this node's key", ok: true, detail: `ed25519 · ${ident.identity.fingerprint}` },
      ];
      try {
        const res = await fetch(`${target}/api/fed/redeem`, {
          method: "POST",
          headers: { "content-type": "application/json" },
          body: JSON.stringify(body),
          signal: AbortSignal.timeout(8000),
        });
        const out = (await res.json()) as FedRedeemResponse & ErrorResponse;
        if (!res.ok || out.error) throw new Error(out.error ?? `${res.status}`);
        steps.push({ n: 4, label: "they verified it and issued us a token", wire: `POST ${target}/api/fed/redeem`, ok: true, detail: `${out.node} · ${out.pubkey.slice(0, 16)}` });
        const entry = fedMembers.adopt(
          { node: out.node, pubkey: out.pubkey, url: out.url ?? target, ourToken: offerToken, theirToken: out.memberToken },
          [...steps, { n: 5, label: "store the membership and start syncing", ok: true, detail: `${out.node} is now a member of ${config.node}` }],
          `we joined them at ${target} · their invite ${token.trim().slice(0, 8)}…`,
        );
        fed.addPeer(out.node, out.url ?? target);
        await saveConfig();
        void fed.pullAll();
        return json<RedeemResponse>({ joined: { node: out.node, url: out.url ?? target }, entry });
      } catch (err) {
        const detail = String(err).replace(/^Error:\s*/, "");
        steps.push({ n: 4, label: "present the invite", wire: `POST ${target}/api/fed/redeem`, ok: false, detail });
        fedMembers.record("redeem.reject", target, steps, detail, `at ${target}`);
        return json<ErrorResponse>({ error: detail }, 400);
      }
    }

    if (path === "/api/members") return json({ members: fedMembers.members, bans: fedMembers.bans });
    if (path === "/api/audit") return json({ audit: fedMembers.audit.slice(0, Number(url.searchParams.get("limit") ?? 100)) });

    const act = path.match(/^\/api\/members\/([^/]+)\/(kick|ban|unban)$/);
    if (act && req.method === "POST") {
      const node = decodeURIComponent(act[1]);
      const { reason } = (await req.json().catch(() => ({}))) as KickRequest;
      if (node === config.node) return json<ErrorResponse>({ error: "a node cannot kick itself" }, 400);

      if (act[2] === "unban") {
        const entry = fedMembers.unban(node);
        return entry ? json<KickResponse>({ entry }) : json<ErrorResponse>({ error: `${node} is not banned here` }, 404);
      }
      const entry = act[2] === "ban" ? fedMembers.ban(node, reason) : fedMembers.kick(node, reason);
      if (!entry) return json<ErrorResponse>({ error: `${node} is not a member of this node` }, 404);
      fed.leave(node);
      await saveConfig();
      return json<KickResponse>({ entry });
    }

    /** A peer published a kick; adopting it is a click here and nothing else. */
    if (path === "/api/audit/adopt" && req.method === "POST") {
      const { node, from, reason } = (await req.json()) as AdoptRequest & { from?: string };
      if (!node || !from) return json<ErrorResponse>({ error: "need the node and who kicked it" }, 400);
      const entry = fedMembers.adoptKick({ node, from, reason });
      if (!entry) return json<ErrorResponse>({ error: `${node} is not a member of this node` }, 404);
      fed.leave(node);
      await saveConfig();
      return json<KickResponse>({ entry });
    }

    if (path === "/api/admin") {
      const mine = new Set(fedMembers.members.map((m) => m.node));
      // one row per node: a peer that kicked the same node three times is still one decision to make
      const latest = new Map<string, AuditEntry & { from: string }>();
      for (const [from, entries] of Object.entries(fed.peerKicks))
        for (const e of entries ?? [])
          if (e.action === "member.kick" && mine.has(e.node) && e.node !== config.node) {
            const seen = latest.get(e.node);
            if (!seen || Date.parse(e.at) > Date.parse(seen.at)) latest.set(e.node, { ...e, from });
          }
      const adoptable = [...latest.values()];
      // One place computes reciprocity, so the CLI map and the web map cannot
      // drift. `stale` is the important half: a peer's reported membership only
      // arrives on a successful pull, and the cache keeps answering while the
      // link is down — measured, a node kept drawing a mutual edge to a peer
      // that had kicked it, while every pull returned 401.
      const edges = fed.peers.map((p) => {
        const h = fed.health[p.name] ?? { consecutive: 0 };
        const stale = (h.consecutive ?? 0) > 0;
        const ours = mine.has(p.name);
        const theirs = (fed.peerFederated[p.name] ?? []).some((m) => m.node === config.node);
        return {
          peer: p.name,
          url: p.url,
          ours,
          theirs,
          mutual: ours && theirs && !stale,
          stale,
          // agents, not panes: a bare shell is a pane herdr found no agent in, and
          // the map's list filters the same way — two counts that disagree read as a bug
          panes: (fed.peerMembers[p.name] ?? []).filter((m) => m.kind && m.kind !== "shell").length,
          ok: h.ok,
          consecutive: h.consecutive ?? 0,
          lastSeen: h.lastSeen,
          lastOkAt: h.lastOkAt,
          lastError: h.lastError,
        };
      });
      const heard = Object.values(fed.known).filter((k) => !fed.peers.some((p) => p.name === k.node));

      return json<AdminState>({
        node: config.node,
        identity: ident.identity,
        legacyAllowed: ALLOW_LEGACY,
        members: fedMembers.members,
        invites: fedMembers.invites,
        bans: fedMembers.bans,
        audit: fedMembers.audit.slice(0, 200),
        meshMembers: fed.peerFederated,
        adoptable,
        edges,
        heard,
        panes: members,
        peerPanes: allPeerMembers(),
        relayed: fed.relayed,
      });
    }

    // ── state for the UI ────────────────────────────────────────────
    if (path === "/api/status") {
      return json<StatusResponse>({
        node: config.node,
        identity: ident.identity,
        legacyAllowed: ALLOW_LEGACY,
        session: process.env.HERDR_SESSION ?? null,
        invite: invite(),
        topology,
        gossip: !!config.gossip,
        stats: fed.stats,
        members,
        messages: fed.messages.slice(-60).reverse(),
        // direct links first, then what hubs let us see — every reader that
        // walks `peers` now walks the whole reachable fleet
        peers: [
          ...fed.peers.map((p) => ({ name: p.name, url: p.url, via: p.via, ...fed.health[p.name] })),
          ...relayedViews(),
        ],
        peerMembers: allPeerMembers(),
        peerUi: allPeerUi(),
        known: Object.values(fed.known),
        relayed: fed.relayed,
      });
    }

    if (path.startsWith("/api/pane/")) {
      const paneId = decodeURIComponent(path.slice("/api/pane/".length));
      if (!validPane(paneId)) return json({ error: "bad pane id" }, 400);
      try {
        const read = await herdr.readPane(paneId, { source: url.searchParams.get("source") ?? "visible", lines: Number(url.searchParams.get("lines") ?? 200) });
        return json(read);
      } catch (err) {
        return json({ error: String(err) }, 502);
      }
    }

    // ── sending ─────────────────────────────────────────────────────
    if (path === "/api/hey" && req.method === "POST") {
      const { to, text } = (await req.json()) as HeyRequest;
      if (!text?.trim()) return json({ error: "empty message" }, 400);
      try {
        if (to && to !== "*") {
          const t = await deliverLocal(to, text.trim());
          return json<HeyResponse>({ delivered: "pane", to: t.handle, pane: t.pane });
        }
        const msg = await fed.post(config.node, text.trim());
        return json<HeyResponse>({ delivered: "channel", id: msg.id });
      } catch (err) {
        return json({ error: String(err) }, 500);
      }
    }

    if (path === "/api/broadcast" && req.method === "POST") {
      const { targets, text } = (await req.json()) as BroadcastRequest;
      if (!text?.trim()) return json({ error: "empty message" }, 400);
      if (!targets?.length) return json({ error: "no targets" }, 400);

      const results = await Promise.all(
        targets.map(async (t): Promise<BroadcastResult> => {
          try {
            const to = t.pane ?? t.handle;
            if (t.node && t.node !== config.node) {
              // Routed by NODE, never by the `base` a client sent: a direct peer
              // gets an authenticated /api/fed/hey, a relayed node goes to its
              // hub's /api/fed/relay. The old hop — an unauthenticated POST to
              // whatever address the client named — is gone.
              let res: Response;
              if (fed.peer(t.node)) {
                res = await fed.call(t.node, "/api/fed/hey", { method: "POST", body: JSON.stringify({ to, text: text.trim() }) });
              } else if (fed.relayed[t.node]) {
                const hub = fed.relayed[t.node].via;
                res = await fed.call(hub, "/api/fed/relay", { method: "POST", body: JSON.stringify({ node: t.node, to, text: text.trim() }) });
              } else {
                throw new Error(`no route to ${t.node} — not a peer, and no hub relays it`);
              }
              const out = await res.json();
              if (!res.ok || out.error) throw new Error(out.error ?? `${t.node} answered ${res.status}`);
              return { handle: t.handle, node: t.node, ok: true, via: "peer" };
            }
            await deliverLocal(to, text.trim());
            return { handle: t.handle, node: t.node ?? config.node, ok: true, via: "local" };
          } catch (err) {
            return { handle: t.handle, node: t.node, ok: false, error: String(err).replace(/^Error:\s*/, "") };
          }
        }),
      );
      return json({ results });
    }

    // ── the console ─────────────────────────────────────────────────
    if (existsSync(DIST)) {
      const rel = path === "/" || !path.includes(".") ? "index.html" : path.slice(1);
      const file = Bun.file(join(DIST, rel));
      if (await file.exists()) return new Response(file);
    }
    return new Response(
      "the console is not built yet — run `bun install && bun run build` in web/",
      { status: 503, headers: { "content-type": "text/plain" } },
    );
  },

  websocket: {
    open(ws) {
      const push = async () => {
        try {
          // MUST be `visible`: a `recent` read asks for scrollback, and for an idle
          // agent herdr collects it by driving the pane's own mouse-scroll — the
          // operator literally watches their terminal scroll up and snap back, once
          // per read (and a 400-line `recent` text read measured 13.8s). `visible`
          // is the rendered viewport, clamped, immune by construction.
          // Its `revision` never moves, so the diff is on the text itself.
          const read = await herdr.readPane(ws.data.paneId, { source: "visible", lines: 200, format: ws.data.format });
          const text = read.text ?? "";
          if (text === ws.data.last) return;
          ws.data.last = text;
          ws.send(JSON.stringify({ type: "frame", text, revision: read.revision } satisfies PaneServerMessage));
        } catch (err) {
          ws.send(JSON.stringify({ type: "error", error: String(err) } satisfies PaneServerMessage));
        }
      };
      ws.data.push = push;
      const set = watchers.get(ws.data.paneId) ?? new Set();
      set.add(ws as any);
      watchers.set(ws.data.paneId, set);

      void push();
      ws.data.timer = setInterval(push, PANE_MS);
    },
    async message(ws, raw) {
      try {
        const msg = JSON.parse(String(raw)) as PaneClientMessage;
        if (msg.type === "text" && msg.text) await herdr.sendText(ws.data.paneId, msg.text);
        else if (msg.type === "keys" && msg.keys?.length) await herdr.sendKeys(ws.data.paneId, msg.keys);
        else if (msg.type === "prompt" && msg.text) await herdr.prompt(ws.data.paneId, msg.text);
        ws.data.last = undefined;
        nudge(ws.data.paneId); // show it now, do not wait for the next tick
      } catch (err) {
        ws.send(JSON.stringify({ type: "error", error: String(err) }));
      }
    },
    close(ws) {
      if (ws.data.timer) clearInterval(ws.data.timer);
      watchers.get(ws.data.paneId)?.delete(ws as any);
    },
  },
});

async function sync() {
  await refreshMembers();
  await fed.pullAll();
  await fed.pushAll();
}

await sync();
setInterval(sync, SYNC_MS);

console.log(`[fed] node=${config.node} peers=${fed.peers.map((p) => p.name).join(",") || "none"} gossip=${!!config.gossip}`);
console.log(`[fed] herdr socket ${herdr.SOCKET_PATH}`);
console.log(`[fed] console http://${HOST}:${server.port}`);

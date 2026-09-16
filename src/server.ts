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
  BroadcastRequest, BroadcastResult, CallsResponse, ErrorResponse, FedState, HeyRequest,
  HeyResponse, IngestRequest, IngestResponse, Invite, JoinRequest, JoinResponse, LeaveRequest,
  LeaveResponse, Member, PaneClientMessage, PaneServerMessage, StatusResponse, Topology, UiTab, UiWorkspace,
} from "./wire";
import { Federation, type FedConfig, type FedMessage } from "./federation";

// import.meta.dir, not new URL().pathname — the latter percent-encodes the ψ in the repo path
const ROOT = join(import.meta.dir, "..");
const CONFIG_PATH = process.env.FED_CONFIG ?? join(ROOT, "peers.json");
const STATE_PATH = process.env.FED_STATE ?? join(ROOT, ".fed-state.json");
const DIST = join(ROOT, "web", "dist");
const PORT = Number(process.env.FED_PORT ?? 6750);
const HOST = process.env.FED_HOST ?? "127.0.0.1";
const SYNC_MS = Number(process.env.FED_SYNC_MS ?? 2000);
const PANE_MS = Number(process.env.FED_PANE_MS ?? 300);

const config: FedConfig = await Bun.file(CONFIG_PATH).json();
const fed = new Federation(config, STATE_PATH);
fed.advertised = process.env.FED_ADVERTISE ? `http://${process.env.FED_ADVERTISE}:${process.env.FED_PORT ?? 6750}` : undefined;
await fed.load();

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
  const host = process.env.FED_ADVERTISE ?? (HOST === "127.0.0.1" ? null : HOST);
  return {
    node: config.node,
    session: process.env.HERDR_SESSION ?? null,
    socket: herdr.SOCKET_PATH,
    url: host ? `http://${host}:${PORT}` : null,
    hint: host ? null : "bind beyond loopback (FED_HOST) or set FED_ADVERTISE to be joinable",
  };
}

/** Panes are addressed as `wD:p4`; anything else is not ours to open. */
const validPane = (id: string) => /^[A-Za-z0-9_:-]+$/.test(id);

type PaneSocket = { paneId: string; format: "text" | "ansi"; timer?: ReturnType<typeof setInterval>; last?: string; push?: () => Promise<void> };

/** Who is watching what, so a send can refresh those viewers at once. */
const watchers = new Map<string, Set<{ data: PaneSocket }>>();

/** After we type into a pane, push a frame now instead of waiting for the next tick. */
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
      return json<FedState>({
        node: config.node,
        messages: fed.messages,
        members,
        peers: fed.peers.map((p) => ({ name: p.name, url: p.url, via: p.via })),
      });
    }
    if (path === "/api/fed/ingest" && req.method === "POST") {
      const body = (await req.json()) as IngestRequest;
      return json<IngestResponse>({ added: fed.ingest(body.messages ?? [], body.from), node: config.node });
    }

    if (path === "/api/invite") return json(invite());

    /** every socket transaction this node has made, with its CLI equivalent */
    if (path === "/api/calls")
      return json<CallsResponse>({ calls: herdr.calls().slice(0, Number(url.searchParams.get("limit") ?? 80)) });

    if (path === "/api/peers/join" && req.method === "POST") {
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

    // ── state for the UI ────────────────────────────────────────────
    if (path === "/api/status") {
      return json<StatusResponse>({
        node: config.node,
        session: process.env.HERDR_SESSION ?? null,
        invite: invite(),
        topology,
        gossip: !!config.gossip,
        stats: fed.stats,
        members,
        messages: fed.messages.slice(-60).reverse(),
        peers: fed.peers.map((p) => ({ name: p.name, url: p.url, via: p.via, ...fed.health[p.name] })),
        peerMembers: fed.peerMembers,
        peerUi: fed.peerUi,
        known: Object.values(fed.known),
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
          const target = members.find((m) => m.pane === to || m.handle === to);
          if (!target) return json({ error: `no agent ${to} on ${config.node}` }, 404);
          await herdr.prompt(target.pane, text.trim());
          nudge(target.pane);
          return json<HeyResponse>({ delivered: "pane", to: target.handle, pane: target.pane });
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
            if (t.node && t.node !== config.node && t.base) {
              const res = await fetch(`${t.base}/api/hey`, {
                method: "POST",
                headers: { "content-type": "application/json" },
                body: JSON.stringify({ to: t.pane ?? t.handle, text: text.trim() }),
                signal: AbortSignal.timeout(5000),
              });
              const out = await res.json();
              if (out.error) throw new Error(out.error);
              return { handle: t.handle, node: t.node, ok: true, via: "peer" };
            }
            const target = members.find((m) => m.pane === t.pane || m.handle === t.handle);
            if (!target) throw new Error("agent not found here");
            await herdr.prompt(target.pane, text.trim());
            nudge(target.pane);
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

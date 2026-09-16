/**
 * Herdr socket client — the only thing this service talks to.
 *
 * Transport (verified against the published contract):
 *   - Unix socket at $HERDR_SOCKET_PATH, newline-delimited JSON
 *   - request  {"id": <string>, "method": <string>, "params": <object>}   id MUST be a string
 *   - response {"id", "result": {"type": ...}} | {"id": "", "error": {code, message}}
 *   - RPC is ONE-SHOT: the server closes after a single response, so every call
 *     opens its own connection. `events.subscribe` is the one exception and
 *     keeps streaming.
 *   - a request line is capped at 1 MiB.
 */

import { connect } from "node:net";
import type { Agent, Method, Pane, PaneRead, Params, Reply, Result, Snapshot } from "./protocol";

export type * from "./protocol";

export const SOCKET_PATH =
  process.env.HERDR_SOCKET_PATH ?? `${process.env.HOME}/.config/herdr/herdr.sock`;

const MAX_LINE = 1024 * 1024;

export class HerdrError extends Error {
  constructor(readonly code: string, message: string) {
    super(message);
  }
}

let seq = 0;

export type Call = {
  at: string;
  method: string;
  params: Readonly<Record<string, unknown>>;
  /** the equivalent you could have typed, when the CLI exposes one */
  cli: string | null;
  ms: number;
  ok: boolean;
  error?: string;
};

const CALLS: Call[] = [];
export const calls = () => CALLS;

const q = (v: unknown) => {
  const s = String(v ?? "");
  return /^[A-Za-z0-9_:.\/-]+$/.test(s) ? s : JSON.stringify(s);
};

/**
 * The same operation as a herdr command line, so every transaction the console
 * makes is inspectable and reproducible by hand. Null where the CLI has no verb
 * for it and the socket is the only way.
 */
export function toCli(method: string, p: Record<string, unknown>): string | null {
  const s = (k: string) => (p[k] === undefined ? "" : String(p[k]));
  switch (method) {
    case "session.snapshot":
      return "herdr api snapshot";
    case "agent.list":
      return "herdr agent list";
    case "pane.list":
      return "herdr pane list";
    case "workspace.list":
      return "herdr workspace list";
    case "pane.read":
      // the CLI defaults --source to `recent`; we always pass ours explicitly
      return `herdr pane read ${q(p.pane_id)} --source ${s("source") || "recent"} --lines ${s("lines")} --format ${s("format") || "text"}`.replace(/\s+--lines\s(?=--)/, " ");
    case "pane.send_keys":
      return `herdr agent send-keys ${q(p.pane_id)} ${(Array.isArray(p.keys) ? p.keys : []).map(q).join(" ")}`;
    case "pane.send_text":
      // no CLI verb writes raw text without submitting; `agent prompt` is text+Enter
      return null;
    default:
      return null;
  }
}

function record(entry: Call) {
  CALLS.unshift(entry);
  CALLS.length = Math.min(CALLS.length, 200);
}

/** One request, one connection, one reply. */
export function call<M extends Method>(method: M, params: Params<M> = {} as Params<M>, timeoutMs = 5000): Promise<Result<M>> {
  const started = Date.now();
  const at = new Date().toISOString();
  const finish = (ok: boolean, error?: string) =>
    record({ at, method, params, cli: toCli(method, params), ms: Date.now() - started, ok, error });
  const line = JSON.stringify({ id: `fed-${++seq}`, method, params }) + "\n";
  if (Buffer.byteLength(line) >= MAX_LINE) {
    return Promise.reject(new HerdrError("request_too_large", `${method} exceeds the 1 MiB request cap`));
  }

  return new Promise<Result<M>>((resolve, reject) => {
    const socket = connect(SOCKET_PATH);
    let buf = "";
    let settled = false;

    const done = (fn: () => void) => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      socket.destroy();
      fn();
    };

    const timer = setTimeout(() => done(() => reject(new HerdrError("timeout", `${method} timed out`))), timeoutMs);

    socket.on("connect", () => socket.write(line));
    socket.on("data", (chunk) => {
      buf += chunk.toString();
      const nl = buf.indexOf("\n");
      if (nl === -1) return;
      try {
        // the one place that has to trust the wire
        const msg = JSON.parse(buf.slice(0, nl)) as Reply<Result<M>>;
        if (msg.error) {
          const { code, message } = msg.error;
          finish(false, message ?? code);
          done(() => reject(new HerdrError(code ?? "error", message ?? "herdr error")));
        } else {
          finish(true);
          done(() => resolve(msg.result as Result<M>));
        }
      } catch (err) {
        done(() => reject(new HerdrError("bad_response", String(err))));
      }
    });
    socket.on("error", (err) => {
      finish(false, err.message);
      done(() => reject(new HerdrError("socket", err.message)));
    });
    // the server closing before a reply is itself the failure signal
    socket.on("close", () => done(() => reject(new HerdrError("closed", `${method}: connection closed with no reply`))));
  });
}

/** The whole herd in one RPC; falls back to the older trio on servers that lack it. */
export async function snapshot(): Promise<Snapshot> {
  try {
    return (await call("session.snapshot")).snapshot;
  } catch (err) {
    if (!(err instanceof HerdrError)) throw err;
    // older servers predate session.snapshot; rebuild what we can from the trio
    const [workspaces, panes] = await Promise.all([call("workspace.list"), call("pane.list")]);
    return { workspaces: workspaces.workspaces, tabs: [], panes: panes.panes, agents: [] };
  }
}

export async function agents(): Promise<Agent[]> {
  return (await call("agent.list")).agents ?? [];
}

/**
 * source ∈ visible | recent | recent_unwrapped | detection — snake_case on the wire.
 *
 * Use `visible` for anything on a timer. `recent` asks for scrollback, and on an
 * idle agent herdr gathers it by driving the pane's own mouse-scroll: the operator
 * sees their terminal scroll and snap back once per read, and a 400-line `recent`
 * text read has been measured at 13.8s. `visible` is the rendered viewport and is
 * immune by construction — at the cost of a `revision` that never moves, so diff
 * on the text.
 */
export async function readPane(
  paneId: string,
  opts: { source?: string; lines?: number; format?: string } = {},
): Promise<PaneRead> {
  const res = await call("pane.read", {
    pane_id: paneId,
    source: opts.source ?? "visible",
    lines: opts.lines ?? 200,
    format: opts.format ?? "text",
  });
  return "read" in res ? res.read : res;
}

/** Writes RAW bytes — no bracketed paste, and no Enter. */
export const sendText = (paneId: string, text: string) => call("pane.send_text", { pane_id: paneId, text });

/**
 * Key grammar is herdr's own, NOT tmux: `Enter`, `Escape`, `ctrl+c`, `shift+tab`,
 * bare single characters. `C-c` and PageUp/Home/End are rejected as invalid_key.
 */
export const sendKeys = (paneId: string, keys: string[]) => call("pane.send_keys", { pane_id: paneId, keys });

/** Type a line and submit it, the two-step herdr requires. */
export async function prompt(paneId: string, text: string) {
  await sendText(paneId, text);
  await sendKeys(paneId, ["Enter"]);
}

export const isUp = async () => {
  try {
    await call("pane.list", {} as Params<"pane.list">, 1500);
    return true;
  } catch {
    return false;
  }
};

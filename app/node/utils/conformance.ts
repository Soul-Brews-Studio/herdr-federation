#!/usr/bin/env bun
/**
 * conformance.ts — `just swift conformance`.
 *
 * Boots the Bun node and the Swift node side by side, from scratch state under
 * .tmp/conformance/, sends each the same request, and compares what came back:
 * status, content-type, and the body PARSED — never the bytes. Object member
 * order is checked separately and reported, not failed: a Swift Dictionary has
 * no insertion order, so a `Record<string, …>` field (peerMembers, peerUi,
 * relayed, meshMembers, peerPanes, a call's params) is allowed to differ there.
 * Every other object is expected in the order the Bun literal builds it, and
 * every Swift body must be `JSON.stringify`-stable (re-serialising the parsed
 * body reproduces the bytes — escaping and number format).
 *
 * Then the runtimes federate with each other in BOTH directions, on two pairs
 * with identical histories: Bun issues and Swift redeems (pair A), Swift issues
 * and Bun redeems (pair B). Same-role bodies are compared ACROSS the pairs —
 * the Bun issuer against the Swift issuer, the Bun joiner against the Swift
 * joiner — because an issuer and its joiner are not mirror images (viaInvite,
 * invites, audit). A third pair proves the token path with FED_ALLOW_LEGACY=0
 * and no herdr at all, and is then used, last, for the dead-socket transport
 * checks that Bun does not survive.
 *
 * Volatile values (timestamps, random ids, keys, tokens, pane text, counters)
 * are compared for presence and type only. Nothing here prints a token, an
 * invite URL, or a private key: diff output is redacted by key name.
 *
 * Panes are only ever READ. No text or keys are sent to any pane.
 */

import { join } from "node:path";
import { existsSync, mkdirSync, rmSync, readdirSync } from "node:fs";
import type { Subprocess } from "bun";

const ROOT = join(import.meta.dir, "..", "..", "..");
const BIN = join(ROOT, "app/node/.build/debug/herdr-federation-node");
const SCRATCH = join(ROOT, ".tmp/conformance");
const SYNC_MS = 2000;

type Runtime = "bun" | "swift";
type Spec = { name: string; runtime: Runtime; port: number; socket?: string; legacy?: "0" | "1" };
type Node = Spec & { base: string; proc: Subprocess; dir: string; env: Record<string, string> };
type Reply = { status: number; ct: string; text: string; json?: unknown; headers: Headers };
type Case = {
  name: string;
  method?: string;
  path: string | ((n: Node) => string);
  body?: unknown | ((n: Node) => unknown);
  raw?: string;
  /** re-run when only the herdr roster drifted between the two reads */
  retry?: boolean;
};
type Row = { name: string; bun: string; swift: string; verdict: string; ok: boolean };
type Identity = { name: string; port: number };

const procs: Subprocess[] = [];
const rows: Row[] = [];
let failures = 0;
/** while set, only a failing compare adds a row (the second pair's identical history) */
let quietPrefix: string | null = null;

function log(s: string) { console.log(`[conformance] ${s}`); }
function fail(s: string): never { log(`FAIL: ${s}`); process.exit(1); }

// ── boot ────────────────────────────────────────────────────────────────

function cleanEnv(): Record<string, string> {
  const env: Record<string, string> = {};
  for (const [k, v] of Object.entries(process.env)) {
    if (v === undefined) continue;
    if (k.startsWith("FED_") || k === "HERDR_SESSION" || k === "HERDR_SOCKET_PATH") continue;
    env[k] = v;
  }
  return env;
}

async function boot(spec: Spec): Promise<Node> {
  const dir = join(SCRATCH, spec.name);
  mkdirSync(dir, { recursive: true });
  await Bun.write(join(dir, "peers.json"), JSON.stringify({ node: spec.name, peers: [] }, null, 2));
  const env = {
    ...cleanEnv(),
    FED_CONFIG: join(dir, "peers.json"),
    FED_STATE: join(dir, ".fed-state.json"),
    FED_IDENTITY: join(dir, ".fed-identity.json"),
    FED_MEMBERS: join(dir, ".fed-members.json"),
    FED_PORT: String(spec.port),
    FED_HOST: "127.0.0.1",
    FED_ADVERTISE: "127.0.0.1",
    FED_LOG: "access",
    ...(spec.socket ? { HERDR_SOCKET_PATH: spec.socket } : {}),
    ...(spec.legacy ? { FED_ALLOW_LEGACY: spec.legacy } : {}),
  };
  // stdout and stderr get SEPARATE files on purpose: handed the same Bun.file,
  // the two streams write at independent offsets and stderr silently overwrites
  // the head of stdout — measured, it ate the banner and four access lines.
  const logFile = Bun.file(join(dir, "node.log"));
  const errFile = Bun.file(join(dir, "node.err.log"));
  const cmd = spec.runtime === "bun" ? ["bun", join(ROOT, "src/server.ts")] : [BIN];
  const proc = Bun.spawn(cmd, { cwd: ROOT, env, stdout: logFile, stderr: errFile });
  procs.push(proc);
  const node: Node = { ...spec, base: `http://127.0.0.1:${spec.port}`, proc, dir, env };
  await ready(node);
  return node;
}

/** wait for a node to answer as itself, or die trying */
async function ready(node: Node): Promise<Node> {
  const deadline = Date.now() + 20_000;
  while (Date.now() < deadline) {
    if (node.proc.exitCode !== null) fail(`${node.name} (${node.runtime}) exited ${node.proc.exitCode} at boot — see ${join(node.dir, "node.log")}`);
    try {
      const r = await fetch(`${node.base}/api/status`, { signal: AbortSignal.timeout(1000) });
      if (r.ok) {
        const s = (await r.json()) as { node?: string };
        if (s.node === node.name) return node;
      }
    } catch {
      // not up yet
    }
    await Bun.sleep(100);
  }
  fail(`${node.name} never answered /api/status`);
}

/**
 * Kill a node and start it again on the SAME state files — peers.json is not
 * rewritten, so everything it knows has to come back off disk. This is the only
 * thing that proves .fed-members.json is really a durable credential store and
 * not a cache the process happened to be holding.
 */
async function reboot(node: Node) {
  try { node.proc.kill(); } catch { /* already gone */ }
  await node.proc.exited;
  const logFile = Bun.file(join(node.dir, "node.log"));
  const errFile = Bun.file(join(node.dir, "node.err.log"));
  const cmd = node.runtime === "bun" ? ["bun", join(ROOT, "src/server.ts")] : [BIN];
  node.proc = Bun.spawn(cmd, { cwd: ROOT, env: node.env, stdout: logFile, stderr: errFile });
  procs.push(node.proc);
  await ready(node);
}

/** the nodes on the real herdr socket: wait until each has a roster, so the reads compare */
async function waitForRoster(nodes: Node[]) {
  const deadline = Date.now() + 15_000;
  while (Date.now() < deadline) {
    const ok = await Promise.all(nodes.map(async (n) => {
      const s = (await (await fetch(`${n.base}/api/status`)).json()) as { topology?: { workspaces?: unknown[] }; members?: unknown[] };
      return (s.topology?.workspaces?.length ?? 0) > 0 && (s.members?.length ?? 0) > 0;
    }));
    if (ok.every(Boolean)) return;
    await Bun.sleep(250);
  }
  fail("the real herdr socket gave no roster within 15s — is herdr running?");
}

function shutdown() {
  for (const p of procs) { try { p.kill(); } catch { /* gone */ } }
}
process.on("exit", shutdown);
process.on("SIGINT", () => { shutdown(); process.exit(130); });
process.on("SIGTERM", () => { shutdown(); process.exit(143); });

async function portFree(port: number) {
  try {
    await fetch(`http://127.0.0.1:${port}/api/status`, { signal: AbortSignal.timeout(500) });
    return false;
  } catch {
    return true;
  }
}

async function alive(n: Node) {
  try { return (await fetch(`${n.base}/api/status`, { signal: AbortSignal.timeout(1000) })).ok; } catch { return false; }
}

// ── requests ────────────────────────────────────────────────────────────

async function send(n: Node, c: Case): Promise<Reply> {
  const path = typeof c.path === "function" ? c.path(n) : c.path;
  const body = typeof c.body === "function" ? c.body(n) : c.body;
  const init: RequestInit = { method: c.method ?? "GET", signal: AbortSignal.timeout(10_000) };
  if (c.raw !== undefined) {
    init.body = c.raw;
    init.headers = { "content-type": "application/json" };
  } else if (body !== undefined) {
    init.body = JSON.stringify(body);
    init.headers = { "content-type": "application/json" };
  }
  let r: Response;
  try {
    r = await fetch(`${n.base}${path}`, init);
  } catch (err) {
    // a node that died mid-run is a finding, not a reason to lose the table
    const dead = n.proc.exitCode !== null ? ` (process exited ${n.proc.exitCode})` : "";
    return { status: 0, ct: "", text: `${String(err)}${dead}`, headers: new Headers() };
  }
  const text = await r.text();
  const ct = r.headers.get("content-type") ?? "";
  let json: unknown;
  if (ct.startsWith("application/json")) {
    try { json = JSON.parse(text); } catch { json = undefined; }
  }
  return { status: r.status, ct, text, json, headers: r.headers };
}

// ── comparing ───────────────────────────────────────────────────────────

/** member order is unknowable through a Swift Dictionary — reported, never failed */
const RECORD_KEYS = new Set(["peerMembers", "peerUi", "relayed", "meshMembers", "peerPanes", "params"]);
/**
 * Arrays whose order is not a contract: `known`/`heard`/`adoptable` follow JS
 * object insertion order, which a Swift Dictionary does not keep; `calls` logs
 * the snapshot fallback's two concurrent RPCs in whichever order they failed;
 * `messages` arrive in push/pull timing order.
 */
const SORTED_ARRAYS: Record<string, (x: unknown) => string> = {
  known: (x) => String((x as { node?: unknown })?.node ?? ""),
  heard: (x) => String((x as { node?: unknown })?.node ?? ""),
  adoptable: (x) => String((x as { node?: unknown })?.node ?? ""),
  calls: (x) => String((x as { method?: unknown })?.method ?? ""),
  messages: (x) => String((x as { id?: unknown })?.id ?? ""),
};
/** divergences with a measured cause, printed as such and not counted as failures */
const KNOWN: Record<string, string> = {
  "POST /api/hey (body not JSON)": "Bun.serve runs in development mode on the fleet (NODE_ENV is never set) and answers an unparseable body with its HTML stack-trace page; the Swift node answers text/plain",
  "POST /api/fed/hey (body not JSON)": "same cause — an unreadable body throws out of handle() and Bun.serve's development-mode 500 page answers it; the Swift node answers text/plain",
};
const TIME_KEYS = new Set(["at", "createdAt", "expiresAt", "joinedAt", "lastHeard", "lastSeen", "lastOkAt", "lastErrorAt", "startedAt", "revokedAt"]);
const KEY_KEYS = new Set(["token", "sig", "pubkey", "fingerprint", "memberToken", "offerToken"]);
const ROSTER_KEYS = new Set(["revision", "scrollback", "rows", "focused", "truncated", "agent_status"]);
const STAT_KEYS = new Set(["pushed", "pushErrors", "pullOk", "pullErrors", "pulled", "errors", "bytesOut", "bytesIn"]);
const SECRET_RE = /token|secret|sig$|privateKey/i;

/** a node's own name and address become placeholders, so the two bodies line up; keys too */
function normalizeString(s: string, self: Identity, peer?: Identity): string {
  if (peer) s = s.replaceAll(`127.0.0.1:${peer.port}`, "<peer-host>").replaceAll(peer.name, "<peer>");
  s = s.replaceAll(`127.0.0.1:${self.port}`, "<self-host>").replaceAll(self.name, "<self>");
  s = s.replace(/\/join\/[A-Za-z0-9_-]{16,}/g, "/join/<token>");
  s = s.replace(/redeem:[A-Za-z0-9_-]{32}:/g, "redeem:<token>:");        // the signed message in the audit
  s = s.replace(/token [A-Za-z0-9_-]{6}…/g, "token <token>…");        // redeem step 1
  s = s.replace(/invite [A-Za-z0-9_-]{8}…/g, "invite <token>…");      // redeem summary
  s = s.replace(/\b(id|invite) [a-z0-9]{8}\b/g, "$1 <id>");           // audit details
  s = s.replace(/\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z/g, "<time>");
  s = s.replace(/\b[0-9a-f]{64}\b/g, "<pubkey>").replace(/\b[0-9a-f]{16}\b/g, "<fingerprint>");
  return s;
}

function normalize(v: unknown, self: Identity, peer?: Identity): unknown {
  if (typeof v === "string") return normalizeString(v, self, peer);
  if (Array.isArray(v)) return v.map((x) => normalize(x, self, peer));
  if (v && typeof v === "object") {
    const out: Record<string, unknown> = {};
    for (const [k, x] of Object.entries(v as Record<string, unknown>)) out[normalizeString(k, self, peer)] = normalize(x, self, peer);
    return out;
  }
  return v;
}

function volatile(key: string, parent: Record<string, unknown>, a: unknown, b: unknown): boolean {
  if (TIME_KEYS.has(key) || KEY_KEYS.has(key) || key === "ms") return true;
  if (ROSTER_KEYS.has(key)) return true;
  if (STAT_KEYS.has(key) && "startedAt" in parent) return true;
  if (key === "status" && ("pane" in parent || "paneCount" in parent)) return true;   // an agent's status moves between two reads
  // sync ticks since a link broke: the two pairs are kicked one after the other, so the counters start at different instants
  if (key === "consecutive" && typeof a === "number" && typeof b === "number" && a > 0 && b > 0) return true;
  if (key === "text" && ("pane_id" in parent || ("pane" in parent && "lines" in parent))) return true;   // pane text
  if ((key === "id" || key === "viaInvite") && typeof a === "string" && typeof b === "string" && /^[a-z0-9]{8}$/.test(a) && /^[a-z0-9]{8}$/.test(b)) return true;
  return false;
}

function typeOf(v: unknown): string {
  if (v === null) return "null";
  if (Array.isArray(v)) return "array";
  return typeof v;
}

function redact(path: string, v: unknown): string {
  const key = path.split(".").pop() ?? "";
  if (SECRET_RE.test(key)) return "<redacted>";
  let s = JSON.stringify(v) ?? String(v);
  if (/\/join\//.test(s)) s = s.replace(/\/join\/[^"\s]*/g, "/join/<token>");
  return s.length > 90 ? s.slice(0, 87) + "…" : s;
}

/** the first difference between two parsed bodies, or null; `order` collects member-order differences */
function diff(a: unknown, b: unknown, path: string, order: string[]): string | null {
  const ta = typeOf(a), tb = typeOf(b);
  if (ta !== tb) return `${path}: ${ta} vs ${tb}`;
  if (ta === "array") {
    const aa = a as unknown[], bb = b as unknown[];
    if (aa.length !== bb.length) return `${path}: ${aa.length} items vs ${bb.length}`;
    for (let i = 0; i < aa.length; i++) {
      const d = diff(aa[i], bb[i], `${path}[${i}]`, order);
      if (d) return d;
    }
    return null;
  }
  if (ta === "object") {
    const oa = a as Record<string, unknown>, ob = b as Record<string, unknown>;
    const ka = Object.keys(oa), kb = Object.keys(ob);
    for (const k of ka) if (!(k in ob)) return `${path}.${k}: present on bun, absent on swift`;
    for (const k of kb) if (!(k in oa)) return `${path}.${k}: absent on bun, present on swift`;
    const key = path.split(".").pop()?.replace(/\[\d+\]$/, "") ?? "";
    if (!RECORD_KEYS.has(key)) {
      const common = ka.filter((k) => k in ob);
      const theirs = kb.filter((k) => k in oa);
      if (common.join(",") !== theirs.join(",")) order.push(`${path}: bun [${common.join(",")}] swift [${theirs.join(",")}]`);
    }
    for (const k of ka) {
      const va = oa[k], vb = ob[k];
      if (volatile(k, oa, va, vb)) {
        if (typeOf(va) !== typeOf(vb)) return `${path}.${k}: ${typeOf(va)} vs ${typeOf(vb)}`;
        continue;
      }
      let xa = va, xb = vb;
      const sortKey = SORTED_ARRAYS[k];
      if (sortKey && Array.isArray(va) && Array.isArray(vb)) {
        xa = [...va].sort((p, q) => sortKey(p).localeCompare(sortKey(q)));
        xb = [...vb].sort((p, q) => sortKey(p).localeCompare(sortKey(q)));
      }
      const d = diff(xa, xb, `${path}.${k}`, order);
      if (d) return d;
    }
    return null;
  }
  if (a !== b) return `${path}: ${redact(path, a)} vs ${redact(path, b)}`;
  return null;
}

function cell(r: Reply) {
  return r.status ? `${r.status} ${r.ct || "-"}` : "no answer";
}

/** Swift's bytes must be what JSON.stringify would write for the same object — escaping, numbers, no whitespace */
function jsStable(r: Reply): boolean {
  if (r.json === undefined) return true;
  return JSON.stringify(r.json) === r.text;
}

async function compare(pair: [Node, Node], c: Case, peer?: [Identity, Identity]) {
  const [bun, swift] = pair;
  let attempts = c.retry ? 3 : 1;
  let verdict = "";
  let ok = false;
  let rb: Reply | undefined, rs: Reply | undefined;
  while (attempts-- > 0) {
    [rb, rs] = await Promise.all([send(bun, c), send(swift, c)]);
    const problems: string[] = [];
    if (rb.status === 0 || rs.status === 0) problems.push(`no answer: bun ${rb.status || rb.text} · swift ${rs.status || rs.text}`);
    else if (rb.status !== rs.status) problems.push(`status ${rb.status} vs ${rs.status}`);
    if (rb.ct !== rs.ct) problems.push(`content-type ${JSON.stringify(rb.ct)} vs ${JSON.stringify(rs.ct)}`);
    const corsB = rb.headers.get("access-control-allow-origin"), corsS = rs.headers.get("access-control-allow-origin");
    if (corsB !== corsS) problems.push(`access-control-allow-origin ${JSON.stringify(corsB)} vs ${JSON.stringify(corsS)}`);
    const order: string[] = [];
    if (rb.json !== undefined || rs.json !== undefined) {
      const a = normalize(rb.json, bun, peer?.[0]);
      const b = normalize(rs.json, swift, peer?.[1]);
      const d = diff(a, b, "body", order);
      if (d) problems.push(d);
    } else if (rb.text !== rs.text) {
      const ta = normalizeString(rb.text, bun, peer?.[0]), tb = normalizeString(rs.text, swift, peer?.[1]);
      if (ta !== tb) problems.push(`text ${redact("text", ta)} vs ${redact("text", tb)}`);
    }
    if (!jsStable(rs)) problems.push("swift body is not JSON.stringify-stable (escaping or number format)");
    if (problems.length === 0) {
      ok = true;
      // key NAMES only — an order report never carries a value
      verdict = order.length ? `same (member order differs \u2014 ${order[0]})` : "same";
      break;
    }
    verdict = `DIFFERS: ${problems[0]}`;
    if (!/items vs/.test(problems[0])) break;   // only a roster drift is worth a retry
    await Bun.sleep(300);
  }
  if (!ok && KNOWN[c.name]) {
    ok = true;
    verdict = `differs, known — ${KNOWN[c.name]} (${verdict.replace(/^DIFFERS: /, "")})`;
  }
  if (!ok) failures++;
  if (quietPrefix === null || !ok) rows.push({ name: (quietPrefix ?? "") + c.name, bun: cell(rb!), swift: cell(rs!), verdict, ok });
  return { rb: rb!, rs: rs! };
}

function check(name: string, cond: boolean, detail: string) {
  if (!cond) failures++;
  rows.push({ name, bun: "-", swift: "-", verdict: cond ? `ok — ${detail}` : `FAILED — ${detail}`, ok: cond });
}

// ── the cases ───────────────────────────────────────────────────────────

const MSG = { id: "far:1", node: "far", seq: 1, from: "far", text: "from far", at: "2026-09-22T00:00:00.000Z" };

function firstAsset(): string | null {
  const dir = join(ROOT, "web/dist/assets");
  if (!existsSync(dir)) return null;
  const js = readdirSync(dir).find((f) => f.endsWith(".js"));
  return js ? `/assets/${js}` : null;
}

/** every route once, on a node with no peers. Mutating cases leave BOTH pairs with the same history. */
async function singleNodeCases(pair: [Node, Node], realPane: string) {
  const self = (n: Node) => n.name;
  const cases: Case[] = [
    { name: "GET /api/status", path: "/api/status", retry: true },
    { name: "GET /api/invite", path: "/api/invite" },
    { name: "GET /api/calls?limit=3", path: "/api/calls?limit=3" },
    { name: "GET /api/calls?limit=abc", path: "/api/calls?limit=abc" },
    { name: "GET /api/members", path: "/api/members" },
    { name: "GET /api/audit?limit=2", path: "/api/audit?limit=2" },
    { name: "GET /api/admin", path: "/api/admin", retry: true },
    { name: "GET /api/fed/state", path: "/api/fed/state", retry: true },
    { name: "POST /api/fed/ingest (one message)", method: "POST", path: "/api/fed/ingest", body: { messages: [MSG], from: { node: "far", url: "http://far:6750" } } },
    { name: "POST /api/fed/ingest (same message again)", method: "POST", path: "/api/fed/ingest", body: { messages: [MSG] } },
    { name: "GET /api/status (after ingest)", path: "/api/status", retry: true },
    { name: "POST /api/fed/hey {}", method: "POST", path: "/api/fed/hey", body: {} },
    { name: "POST /api/fed/hey unknown agent", method: "POST", path: "/api/fed/hey", body: { to: "nope", text: " hi " } },
    { name: "POST /api/fed/pane bad id", method: "POST", path: "/api/fed/pane", body: { pane: "bad pane" } },
    { name: "POST /api/fed/pane real pane", method: "POST", path: "/api/fed/pane", body: { pane: realPane, lines: 5 } },
    { name: "POST /api/fed/pane lines=0 (→40)", method: "POST", path: "/api/fed/pane", body: { pane: realPane, lines: 0 } },
    { name: "POST /api/fed/pane lines=9999 (→400)", method: "POST", path: "/api/fed/pane", body: { pane: realPane, lines: 9999 } },
    { name: "POST /api/fed/pane-relay no route", method: "POST", path: "/api/fed/pane-relay", body: { node: "nope", pane: "w1:p1" } },
    { name: "POST /api/fed/pane-relay {}", method: "POST", path: "/api/fed/pane-relay", body: {} },
    { name: "POST /api/fleet/pane self", method: "POST", path: "/api/fleet/pane", body: (n: Node) => ({ node: self(n), pane: realPane, lines: 3 }) },
    { name: "POST /api/fleet/pane self bad id", method: "POST", path: "/api/fleet/pane", body: (n: Node) => ({ node: self(n), pane: "bad pane" }) },
    { name: "POST /api/fleet/pane no route", method: "POST", path: "/api/fleet/pane", body: { node: "nope", pane: "w1:p1" } },
    { name: "POST /api/fleet/hey no route", method: "POST", path: "/api/fleet/hey", body: { node: "nope", to: "x", text: "y" } },
    { name: "POST /api/fleet/hey self unknown agent", method: "POST", path: "/api/fleet/hey", body: (n: Node) => ({ node: self(n), to: "nope", text: "y" }) },
    { name: "POST /api/fleet/hey {}", method: "POST", path: "/api/fleet/hey", body: {} },
    { name: "POST /api/fed/relay no route", method: "POST", path: "/api/fed/relay", body: { node: "nope", to: "x", text: "y" } },
    { name: "POST /api/fed/redeem unknown invite", method: "POST", path: "/api/fed/redeem", body: { token: "not-a-token", node: "z", pubkey: "00", url: "http://z", offerToken: "t", at: "2026-09-22T00:00:00.000Z", sig: "x" } },
    { name: "POST /api/fed/redeem self", method: "POST", path: "/api/fed/redeem", body: (n: Node) => ({ token: "t", node: self(n), pubkey: "00", offerToken: "t", at: "2026-09-22T00:00:00.000Z", sig: "x" }) },
    { name: "POST /api/invites {}", method: "POST", path: "/api/invites", body: {} },
    { name: "POST /api/invites hours:null uses:1 note", method: "POST", path: "/api/invites", body: { hours: null, uses: 1, note: "it" } },
    { name: "POST /api/invites (unreadable body)", method: "POST", path: "/api/invites", raw: "not json" },
    { name: "GET /api/invites", path: "/api/invites" },
    { name: "GET /api/invite-preview/nope", path: "/api/invite-preview/nope" },
    { name: "DELETE /api/invites/nope", method: "DELETE", path: "/api/invites/nope" },
    { name: "POST /api/peers/join {}", method: "POST", path: "/api/peers/join", body: {} },
    { name: "POST /api/peers/join dead address", method: "POST", path: "/api/peers/join", body: { url: "http://127.0.0.1:1" } },
    { name: "POST /api/peers/leave", method: "POST", path: "/api/peers/leave", body: { name: "x" } },
    { name: "POST /api/peers/leave {}", method: "POST", path: "/api/peers/leave", body: {} },
    { name: "POST /api/peers/redeem {}", method: "POST", path: "/api/peers/redeem", body: {} },
    { name: "POST /api/peers/redeem dead address", method: "POST", path: "/api/peers/redeem", body: { from: "http://127.0.0.1:1/", token: "abcdefghij" } },
    { name: "POST /api/members/nope/kick", method: "POST", path: "/api/members/nope/kick", body: {} },
    { name: "POST /api/members/<self>/kick", method: "POST", path: (n: Node) => `/api/members/${self(n)}/kick`, body: { reason: "x" } },
    { name: "POST /api/members/nope/unban", method: "POST", path: "/api/members/nope/unban" },
    { name: "POST /api/members/ghost/ban (never a member)", method: "POST", path: "/api/members/ghost/ban", body: { reason: "flooding" } },
    { name: "GET /api/members (after ban)", path: "/api/members" },
    { name: "POST /api/members/ghost/unban", method: "POST", path: "/api/members/ghost/unban" },
    { name: "POST /api/audit/adopt {}", method: "POST", path: "/api/audit/adopt", body: {} },
    { name: "POST /api/audit/adopt not a member", method: "POST", path: "/api/audit/adopt", body: { node: "nope", from: "far" } },
    { name: "GET /api/audit", path: "/api/audit" },
    { name: "GET /api/pane/<real>?lines=5", path: `/api/pane/${realPane}?lines=5` },
    { name: "GET /api/pane/<real>?lines=abc", path: `/api/pane/${realPane}?lines=abc` },
    { name: "GET /api/pane/bad%20pane", path: "/api/pane/bad%20pane" },
    { name: "POST /api/hey {}", method: "POST", path: "/api/hey", body: {} },
    { name: "POST /api/hey channel", method: "POST", path: "/api/hey", body: { text: "  hello from conformance  " } },
    { name: "POST /api/hey to:* channel", method: "POST", path: "/api/hey", body: { to: "*", text: "second" } },
    { name: "POST /api/hey unknown agent", method: "POST", path: "/api/hey", body: { to: "nope", text: "x" } },
    { name: "POST /api/hey (body not JSON)", method: "POST", path: "/api/hey", raw: "not json" },
    { name: "POST /api/fed/hey (body not JSON)", method: "POST", path: "/api/fed/hey", raw: "not json" },
    { name: "POST /api/broadcast {}", method: "POST", path: "/api/broadcast", body: {} },
    { name: "POST /api/broadcast no targets", method: "POST", path: "/api/broadcast", body: { text: "x", targets: [] } },
    { name: "POST /api/broadcast unknown local + no route", method: "POST", path: "/api/broadcast", body: { text: "x", targets: [{ handle: "nope" }, { handle: "h", node: "nope" }] } },
    { name: "GET /api/status (messages)", path: "/api/status", retry: true },
    { name: "GET /", path: "/" },
    { name: "GET /nope (console fallback)", path: "/nope" },
    { name: "GET /nope.js", path: "/nope.js" },
    { name: "GET /ws/pane/<real> (no upgrade)", path: `/ws/pane/${realPane}` },
    { name: "GET /ws/pane/bad%20pane", path: "/ws/pane/bad%20pane" },
    { name: "GET /api/fed/ingest (wrong method → console)", path: "/api/fed/ingest" },
    { name: "PUT /api/status (no method check)", method: "PUT", path: "/api/status", retry: true },
    { name: "HEAD /api/status", method: "HEAD", path: "/api/status" },
  ];
  const asset = firstAsset();
  if (asset) cases.push({ name: "GET /assets/<first js>", path: asset });

  let inviteId: Record<string, string> = {};
  let inviteToken: Record<string, string> = {};
  for (const c of cases) {
    const { rb, rs } = await compare(pair, c);
    if (c.name === "POST /api/invites hours:null uses:1 note") {
      const jb = rb.json as { invite?: { id: string; token: string } }, js = rs.json as { invite?: { id: string; token: string } };
      inviteId = { [pair[0].name]: jb.invite?.id ?? "", [pair[1].name]: js.invite?.id ?? "" };
      inviteToken = { [pair[0].name]: jb.invite?.token ?? "", [pair[1].name]: js.invite?.token ?? "" };
    }
    if (c.name === "GET /api/invites") {
      // each node's OWN invite — the token never leaves this process
      await compare(pair, { name: "GET /api/invite-preview/<own token>", path: (n) => `/api/invite-preview/${encodeURIComponent(inviteToken[n.name])}` });
      await compare(pair, { name: "DELETE /api/invites/<own id>", method: "DELETE", path: (n) => `/api/invites/${inviteId[n.name]}` });
      await compare(pair, { name: "DELETE /api/invites/<own id> again", method: "DELETE", path: (n) => `/api/invites/${inviteId[n.name]}` });
      await compare(pair, { name: "GET /api/invite-preview/<revoked token>", path: (n) => `/api/invite-preview/${encodeURIComponent(inviteToken[n.name])}` });
    }
  }
}

/**
 * The pane WebSocket, the one surface that is not request/response. Both nodes
 * watch the SAME real pane through the same herdr, so the first frame's
 * `revision` is herdr's own number and must agree. Text is only ever measured,
 * never printed. Read-only: nothing is sent into the socket, so nothing reaches
 * the pane.
 */
async function wsParity(pair: [Node, Node], realPane: string) {
  type Frame = { type?: string; text?: string; revision?: unknown; error?: string };
  const watch = (n: Node) => new Promise<Frame[]>((resolve) => {
    const msgs: Frame[] = [];
    let ws: WebSocket;
    try {
      ws = new WebSocket(`ws://127.0.0.1:${n.port}/ws/pane/${encodeURIComponent(realPane)}`);
    } catch {
      return resolve(msgs);
    }
    ws.onmessage = (e) => {
      try { msgs.push(JSON.parse(String(e.data)) as Frame); } catch { msgs.push({ type: "unparseable" }); }
    };
    ws.onerror = () => { /* an empty collection is the finding */ };
    setTimeout(() => { try { ws.close(); } catch { /* already gone */ } resolve(msgs); }, 2200);
  });
  const [mb, ms] = await Promise.all([watch(pair[0]), watch(pair[1])]);
  const fb = mb[0], fs = ms[0];
  const size = (f?: Frame) => (typeof f?.text === "string" ? f.text.length : -1);
  check("ws /ws/pane/<real>: first message is a non-empty frame on both",
    fb?.type === "frame" && fs?.type === "frame" && size(fb) > 0 && size(fs) > 0,
    `bun ${mb.length} message(s), first ${fb?.type ?? "-"} ${size(fb)} chars \u00b7 swift ${ms.length} message(s), first ${fs?.type ?? "-"} ${size(fs)} chars`);
  check("ws /ws/pane/<real>: revision agrees",
    JSON.stringify(fb?.revision) === JSON.stringify(fs?.revision),
    `bun ${JSON.stringify(fb?.revision)} \u00b7 swift ${JSON.stringify(fs?.revision)}`);
  check("ws /ws/pane/<real>: every message parses and is typed",
    mb.every((m) => m.type === "frame" || m.type === "error") && ms.every((m) => m.type === "frame" || m.type === "error"),
    `bun [${[...new Set(mb.map((m) => m.type))].join(",") || "-"}] \u00b7 swift [${[...new Set(ms.map((m) => m.type))].join(",") || "-"}]`);
}

/**
 * `FED_LOG=access` is the fleet default (`server.ts` reads `FED_LOG ?? "access"`),
 * so the access log is a shipped surface and not a debug aid. Both nodes in a
 * pair took exactly the same requests in exactly the same order, so the line
 * each wrote must match once the four values that CANNOT agree are scrubbed:
 * the wall clock, the duration column, the node's own name, and the random
 * invite id / invite secret that some paths carry. Scrubbing the secret is not
 * cosmetic — `/api/invite-preview/<secret>` means BOTH runtimes write a live
 * invite secret into the access log, so a diff of raw lines would reprint it.
 */
function scrubLog(text: string, node: Node): string[] {
  return text
    .split("\n")
    .filter((l) => /^\[\d\d:\d\d:\d\d\] \d{3} /.test(l))
    .map((l) =>
      l
        .replace(/^\[\d\d:\d\d:\d\d\] /, "")
        .replace(/\s*\d+ms.*$/, "")
        .replace(/\/api\/invite-preview\/\S+/, "/api/invite-preview/<secret>")
        .replace(/\/api\/invites\/[a-z0-9]{8}/, "/api/invites/<id>")
        .replaceAll(node.name, "<node>")
        .trimEnd(),
    );
}

/**
 * Walk the two logs together. A Swift-only `500` line is the one difference
 * with a measured cause: a body that will not parse throws out of Bun's
 * `handle()`, so the `done()` wrapper that writes the line never runs and Bun
 * logs NOTHING for a request it answered 500 to. The Swift node logs it.
 */
function alignLogs(a: string[], b: string[]) {
  const extra: string[] = [];
  let i = 0, j = 0, first = -1;
  while (i < a.length && j < b.length) {
    if (a[i] === b[j]) { i++; j++; continue; }
    if (/^500 /.test(b[j])) { extra.push(b[j]); j++; continue; }
    first = i;
    break;
  }
  while (j < b.length && /^500 /.test(b[j])) { extra.push(b[j]); j++; }
  return { extra, first, a, b, restA: a.length - i, restB: b.length - j };
}

async function accessLogParity(pair: [Node, Node], label: string) {
  const [tb, ts] = await Promise.all([
    Bun.file(join(pair[0].dir, "node.log")).text(),
    Bun.file(join(pair[1].dir, "node.log")).text(),
  ]);
  const a = scrubLog(tb, pair[0]), b = scrubLog(ts, pair[1]);
  const r = alignLogs(a, b);
  const aligned = r.first === -1 && r.restA === 0 && r.restB === 0;
  const detail = aligned
    ? r.extra.length === 0
      ? `${a.length} lines, identical once the clock, the ms column, the node name and the invite id/secret are scrubbed`
      : `known \u2014 ${a.length} bun lines against ${b.length} swift; every difference is a 500 Bun never logged because the unparseable body threw out of handle() before done() ran: ${r.extra.join(", ")}`
    : `bun ${a.length} lines \u00b7 swift ${b.length}${r.first < 0 ? "" : `; first difference #${r.first}: ${JSON.stringify(a[r.first])} vs ${JSON.stringify(b[r.first])}`}`;
  check(`${label}: FED_LOG=access logs the same line for the same request`, aligned, detail);
}

/**
 * Spec: restart both, same state dirs, and the federation must come back off
 * disk. Nothing rewrites peers.json here, so a link that recovers is a link
 * whose token survived a process death on both runtimes.
 */
async function rebootPair(pair: [Node, Node], label: string) {
  const [bun, swift] = pair;
  await Promise.all([reboot(bun), reboot(swift)]);
  type Status = { peers: { name: string; ok?: boolean }[] };
  const peerOk = async (n: Node, want: string) => {
    const deadline = Date.now() + 8000;
    while (Date.now() < deadline) {
      const s = await send(n, { name: "", path: "/api/status" });
      const row = (s.json as Status)?.peers?.find((p) => p.name === want);
      if (row?.ok === true) return true;
      await Bun.sleep(400);
    }
    return false;
  };
  const [ob, os] = [await peerOk(bun, swift.name), await peerOk(swift, bun.name)];
  check(`${label}: the link comes back after both processes are killed`, ob && os,
    `read back from .fed-members.json + peers.json: bun\u2192swift ok=${ob} \u00b7 swift\u2192bun ok=${os}`);
}

/** who each federated node's peer is, so a case body can name it without printing it here */
const PEER_OF: Record<string, string> = {
  "bun-a": "swift-a", "swift-a": "bun-a",
  "swift-b": "bun-b", "bun-b": "swift-b",
};

/** routing by node name across the runtime boundary: the peer on the far side is the other implementation */
async function crossFleet(label: string, pair: [Node, Node], peers: [Identity, Identity], realPane: string) {
  const peerName = (n: Node) => PEER_OF[n.name] ?? "";
  const cases: Case[] = [
    { name: `${label}: POST /api/fleet/pane routed to the peer`, method: "POST", path: "/api/fleet/pane", body: (n: Node) => ({ node: peerName(n), pane: realPane, lines: 5 }) },
    { name: `${label}: POST /api/fleet/pane routed to the peer, bad id`, method: "POST", path: "/api/fleet/pane", body: (n: Node) => ({ node: peerName(n), pane: "bad pane" }) },
    { name: `${label}: POST /api/fleet/hey routed to the peer, unknown agent`, method: "POST", path: "/api/fleet/hey", body: (n: Node) => ({ node: peerName(n), to: "nope", text: "x" }) },
    { name: `${label}: POST /api/fed/relay for the peer, unknown agent`, method: "POST", path: "/api/fed/relay", body: (n: Node) => ({ node: peerName(n), to: "nope", text: "x" }) },
  ];
  for (const c of cases) await compare(pair, c, peers);
}

/** an invite redeemed by a node that is ALREADY a member upserts the row, it does not add a second one */
async function reRedeem(issuer: Node, joiner: Node, label: string) {
  const inv = await send(issuer, { name: "", method: "POST", path: "/api/invites", body: { note: "second redeem" } });
  const token = (inv.json as { invite?: { token?: string } })?.invite?.token ?? "";
  const red = await send(joiner, { name: "", method: "POST", path: "/api/peers/redeem", body: { from: `http://127.0.0.1:${issuer.port}`, token } });
  const [ai, aj] = await Promise.all([send(issuer, { name: "", path: "/api/admin" }), send(joiner, { name: "", path: "/api/admin" })]);
  type Admin = { members: { node: string }[] };
  const ni = (ai.json as Admin)?.members?.filter((m) => m.node === joiner.name).length ?? -1;
  const nj = (aj.json as Admin)?.members?.filter((m) => m.node === issuer.name).length ?? -1;
  check(`${label}: a second redeem upserts the member, it does not duplicate it`,
    red.status === 200 && ni === 1 && nj === 1,
    `redeem \u2192 ${red.status}; ${issuer.runtime} issuer holds ${ni} row(s) for the joiner \u00b7 ${joiner.runtime} joiner holds ${nj} for the issuer`);
}

/**
 * FED_ALLOW_LEGACY=0 on both, already federated, and then a kick. The kick is
 * the only thing in the protocol that takes membership away, and the proof that
 * a token is really being checked: the kicked node's very NEXT sync is 401, and
 * the kicker drops the peer outright. An HTTP-status failure is one of the
 * error texts the two runtimes DO share, so `Error: 401` is asserted literally.
 */
async function strictKick(kicker: Node, victim: Node, label: string) {
  const res = await send(kicker, { name: "", method: "POST", path: `/api/members/${victim.name}/kick`, body: { reason: "conformance" } });
  const entry = (res.json as { entry?: { action?: string; node?: string; steps?: unknown[] } })?.entry;
  check(`${label}: ${kicker.runtime} kicks the ${victim.runtime} member`,
    res.status === 200 && entry?.action === "member.kick" && entry?.node === victim.name,
    `POST /api/members/<member>/kick \u2192 ${res.status}, entry ${entry?.action ?? "-"}`);

  type Status = { peers: { name: string; ok?: boolean; consecutive?: number; lastError?: string }[] };
  type Row = { name: string; ok?: boolean; consecutive?: number; lastError?: string };
  let row: Row | undefined;
  const deadline = Date.now() + 8000;
  while (Date.now() < deadline) {
    const s = await send(victim, { name: "", path: "/api/status" });
    row = (s.json as Status)?.peers?.find((p) => p.name === kicker.name);
    if ((row?.consecutive ?? 0) >= 1) break;
    await Bun.sleep(400);
  }
  check(`${label}: the kicked ${victim.runtime} node is 401 on its next sync`,
    (row?.consecutive ?? 0) >= 1 && row?.ok === false && row?.lastError === "Error: 401",
    `peer row: ok=${row?.ok} consecutive=${row?.consecutive} lastError=${JSON.stringify(row?.lastError)}`);

  const [ks, va] = await Promise.all([send(kicker, { name: "", path: "/api/status" }), send(victim, { name: "", path: "/api/admin" })]);
  const kp = (ks.json as Status)?.peers;
  check(`${label}: ${kicker.runtime} dropped the peer as well as the member`,
    Array.isArray(kp) && kp.length === 0,
    `the kicker's /api/status peers: ${Array.isArray(kp) ? kp.length : "-"}`);
  const adoptable = (va.json as { adoptable?: unknown[] })?.adoptable;
  check(`${label}: a kick OF the reader is never adoptable BY the reader`,
    Array.isArray(adoptable) && adoptable.length === 0,
    `the kicked node's /api/admin adoptable: ${Array.isArray(adoptable) ? adoptable.length : "-"} (server.ts excludes e.node === config.node)`);
}

/**
 * A herdr socket that cannot be connected to. Measured on Bun 1.3.14, for a
 * missing path and for a bound socket nobody listens on alike: the sync loop's
 * failed RPCs are logged as `connect ENOENT <path>` and the node lives on, but
 * the first client-facing pane read answers 502 `Error: pane.read: connection
 * closed with no reply` (node:net emits `close` before `error`) and the late
 * `error` event then kills the process (uncaught, from herdr.ts:97). The Swift
 * node answers `Error: connect ENOENT <path>` and stays up. Run LAST for a pair.
 */
async function transportCases(pair: [Node, Node], label: string, peer?: [Identity, Identity]) {
  KNOWN[`${label}: GET /api/pane/w1:p1 (502)`] = "Bun's close event wins the race and its process then exits — see the liveness row";
  await compare(pair, { name: `${label}: GET /api/status`, path: "/api/status" }, peer);
  await compare(pair, { name: `${label}: GET /api/calls?limit=3 (the sync loop's failures)`, path: "/api/calls?limit=3" }, peer);
  await compare(pair, { name: `${label}: GET /api/pane/w1:p1 (502)`, path: "/api/pane/w1:p1" }, peer);
  await Bun.sleep(800);
  const [bun, swift] = pair;
  const [ab, as] = await Promise.all([alive(bun), alive(swift)]);
  const detail = `bun ${ab ? "alive" : `exited ${bun.proc.exitCode ?? "?"}`} · swift ${as ? "alive" : `exited ${swift.proc.exitCode ?? "?"}`}`;
  if (!as) failures++;
  rows.push({ name: `${label}: still serving after the pane read`, bun: ab ? "alive" : "dead", swift: as ? "alive" : "dead", verdict: as ? (ab ? `ok — ${detail}` : `differs, known — Bun 1.3.14 crashes on the late error event (${detail})`) : `FAILED — ${detail}`, ok: as });
}

// ── federation, both directions ─────────────────────────────────────────

async function federate(issuer: Node, joiner: Node, label: string) {
  const inv = await send(issuer, { name: "", method: "POST", path: "/api/invites", body: { note: "conformance" } });
  const token = (inv.json as { invite?: { token?: string } })?.invite?.token ?? "";
  check(`${label}: ${issuer.runtime} issues an invite`, inv.status === 200 && token.length === 32, `POST /api/invites → ${inv.status}, secret is ${token.length} chars`);

  const red = await send(joiner, { name: "", method: "POST", path: "/api/peers/redeem", body: { from: `http://127.0.0.1:${issuer.port}`, token } });
  const rj = red.json as { joined?: { node?: string; url?: string }; entry?: { steps?: { n: number; ok: boolean }[] } } | undefined;
  const steps = rj?.entry?.steps ?? [];
  check(`${label}: ${joiner.runtime} redeems it at ${issuer.runtime}`,
    red.status === 200 && rj?.joined?.node === issuer.name && steps.length === 5 && steps.every((s) => s.ok),
    `POST /api/peers/redeem → ${red.status}, joined ${rj?.joined?.node ?? "-"}, steps ${steps.map((s) => `${s.n}${s.ok ? "✓" : "✗"}`).join(" ")}`);

  await Bun.sleep(2 * SYNC_MS + 800);

  const [si, sj] = await Promise.all([send(issuer, { name: "", path: "/api/status" }), send(joiner, { name: "", path: "/api/status" })]);
  type Status = { peers: { name: string; ok?: boolean; consecutive?: number; lastOkUrl?: string }[]; members: unknown[]; peerMembers: Record<string, unknown[]>; messages: { id: string }[] };
  if (si.json === undefined || sj.json === undefined) {
    check(`${label}: both nodes answering after the redeem`, false, `${issuer.runtime} ${si.status || si.text} · ${joiner.runtime} ${sj.status || sj.text}`);
    return;
  }
  const a = si.json as Status, b = sj.json as Status;
  const pa = a.peers.find((p) => p.name === joiner.name), pb = b.peers.find((p) => p.name === issuer.name);
  check(`${label}: both links healthy after two sync cycles`,
    pa?.ok === true && pa.consecutive === 0 && pb?.ok === true && pb.consecutive === 0,
    `${issuer.runtime}→${joiner.runtime} ok=${pa?.ok} consecutive=${pa?.consecutive} · ${joiner.runtime}→${issuer.runtime} ok=${pb?.ok} consecutive=${pb?.consecutive}`);
  check(`${label}: each side holds the other's roster`,
    (a.peerMembers[joiner.name]?.length ?? -1) === b.members.length && (b.peerMembers[issuer.name]?.length ?? -1) === a.members.length,
    `${issuer.runtime} sees ${a.peerMembers[joiner.name]?.length ?? "-"} of ${joiner.runtime}'s ${b.members.length} · ${joiner.runtime} sees ${b.peerMembers[issuer.name]?.length ?? "-"} of ${issuer.runtime}'s ${a.members.length}`);
  const ids = (s: Status) => new Set(s.messages.map((m) => m.id));
  const mine = `${issuer.name}:1`, theirs = `${joiner.name}:1`;
  const converged = ids(a).has(mine) && ids(a).has(theirs) && ids(b).has(mine) && ids(b).has(theirs);
  check(`${label}: message logs converged`, converged || (a.messages.length === 0 && b.messages.length === 0),
    a.messages.length === 0 && b.messages.length === 0 ? "nothing posted on this pair" : `${issuer.runtime} has ${[...ids(a)].filter((i) => i === mine || i === theirs).length}/2 · ${joiner.runtime} has ${[...ids(b)].filter((i) => i === mine || i === theirs).length}/2`);

  const [mi, mj] = await Promise.all([send(issuer, { name: "", path: "/api/members" }), send(joiner, { name: "", path: "/api/members" })]);
  type Members = { members: { node: string; lastSeen?: string; legacy?: boolean }[] };
  const ri = (mi.json as Members).members.find((m) => m.node === joiner.name), rr = (mj.json as Members).members.find((m) => m.node === issuer.name);
  check(`${label}: tokens authenticate in both directions`,
    !!ri?.lastSeen && !!rr?.lastSeen && !ri.legacy && !rr.legacy,
    `lastSeen stamped by authenticate(): ${issuer.runtime} ${ri?.lastSeen ? "yes" : "no"} · ${joiner.runtime} ${rr?.lastSeen ? "yes" : "no"}`);

  const [ai, aj] = await Promise.all([send(issuer, { name: "", path: "/api/admin" }), send(joiner, { name: "", path: "/api/admin" })]);
  type Admin = { edges: { peer: string; ours: boolean; theirs: boolean; mutual: boolean; stale: boolean }[] };
  const ei = (ai.json as Admin).edges.find((e) => e.peer === joiner.name), ej = (aj.json as Admin).edges.find((e) => e.peer === issuer.name);
  check(`${label}: /api/admin edge is mutual on both sides`, ei?.mutual === true && ej?.mutual === true,
    `${issuer.runtime} ours=${ei?.ours} theirs=${ei?.theirs} stale=${ei?.stale} · ${joiner.runtime} ours=${ej?.ours} theirs=${ej?.theirs} stale=${ej?.stale}`);
}

/** the same role on each runtime: `pair` is [bun, swift], `peers` their respective peers */
async function crossPair(label: string, pair: [Node, Node], peers: [Identity, Identity]) {
  for (const path of ["/api/status", "/api/admin", "/api/members", "/api/fed/state", "/api/invites", "/api/audit?limit=6"]) {
    await compare(pair, { name: `${label}: GET ${path}`, path, retry: true }, peers);
  }
}

// ── main ────────────────────────────────────────────────────────────────

log("building the Swift node (debug)...");
const build = Bun.spawnSync(["swift", "build", "--package-path", join(ROOT, "app/node")], { stdout: "ignore", stderr: "inherit" });
if (build.exitCode !== 0) fail("swift build failed");
if (!existsSync(BIN)) fail(`no binary at ${BIN}`);

const PORTS = [6771, 6772, 6773, 6774, 6775, 6776, 6777, 6778, 6779, 6780, 6781, 6782];
for (const p of PORTS) if (!(await portFree(p))) fail(`port ${p} is already serving something — stop it first`);

rmSync(SCRATCH, { recursive: true, force: true });
mkdirSync(SCRATCH, { recursive: true });

const missingSock = join(SCRATCH, "missing.sock");
const staleSock = join(SCRATCH, "stale.sock");
let haveStale = false;
if (staleSock.length < 100) {
  // bound and never listened on: the kernel says ECONNREFUSED, Bun says ENOENT
  const py = Bun.spawnSync(["python3", "-c", "import socket,sys; s=socket.socket(socket.AF_UNIX); s.bind(sys.argv[1])", staleSock]);
  haveStale = py.exitCode === 0 && existsSync(staleSock);
}

log("booting A bun-a/swift-a and B swift-b/bun-b (real herdr socket), D swift-d/bun-d and the kick pairs F bun-f/swift-f, G swift-g/bun-g (no herdr, FED_ALLOW_LEGACY=0)" + (haveStale ? ", E bun-e/swift-e (stale socket)" : ""));
const specs: Spec[] = [
  { name: "bun-a", runtime: "bun", port: 6771 },
  { name: "swift-a", runtime: "swift", port: 6772 },
  { name: "swift-b", runtime: "swift", port: 6773 },
  { name: "bun-b", runtime: "bun", port: 6774 },
  { name: "swift-d", runtime: "swift", port: 6775, socket: missingSock, legacy: "0" },
  { name: "bun-d", runtime: "bun", port: 6776, socket: missingSock, legacy: "0" },
  // the kick pairs: strict on both sides, roles mirrored so the kicker and the
  // kicked can each be compared across runtimes
  { name: "bun-f", runtime: "bun", port: 6779, socket: missingSock, legacy: "0" },
  { name: "swift-f", runtime: "swift", port: 6780, socket: missingSock, legacy: "0" },
  { name: "swift-g", runtime: "swift", port: 6781, socket: missingSock, legacy: "0" },
  { name: "bun-g", runtime: "bun", port: 6782, socket: missingSock, legacy: "0" },
  ...(haveStale ? [{ name: "bun-e", runtime: "bun" as Runtime, port: 6777, socket: staleSock }, { name: "swift-e", runtime: "swift" as Runtime, port: 6778, socket: staleSock }] : []),
];
const nodes = await Promise.all(specs.map(boot));
const byName = Object.fromEntries(nodes.map((n) => [n.name, n]));
const A: [Node, Node] = [byName["bun-a"], byName["swift-a"]];
const B: [Node, Node] = [byName["bun-b"], byName["swift-b"]];
const D: [Node, Node] = [byName["bun-d"], byName["swift-d"]];

await waitForRoster([...A, ...B]);
// BOTH sides are asked, though only one answer is used: an extra request on one
// node would put its access log one line ahead of the other's
const [rosterRes] = await Promise.all([fetch(`${A[0].base}/api/status`), fetch(`${A[1].base}/api/status`)]);
const roster = (await rosterRes.json()) as { members: { pane: string }[] };
const realPane = roster.members[0]?.pane ?? "w1:p1";
log(`bun-a sees ${roster.members.length} panes; reading ${realPane} (read only — nothing is typed anywhere)`);

function report() {
  console.log("");
  console.log("| case | bun | swift | verdict |");
  console.log("|---|---|---|---|");
  for (const r of rows) console.log(`| ${r.name.replaceAll("|", "\\|")} | ${r.bun} | ${r.swift} | ${r.verdict.replaceAll("|", "\\|")} |`);
  console.log("");
  const pass = rows.filter((r) => r.ok).length;
  const known = rows.filter((r) => r.ok && /known/.test(r.verdict)).length;
  const swiftVersion = Bun.spawnSync(["swift", "--version"]).stdout.toString().split("\n")[0].replace(/^.*Swift version /, "").split(" ")[0];
  log(`${rows.length} checks · ${pass} pass (${known} known divergences) · ${rows.length - pass} fail · bun ${Bun.version} · swift ${swiftVersion} · ${roster.members.length} panes on the real herdr`);
}

try {
  await singleNodeCases(A, realPane);
  quietPrefix = "B: ";
  await singleNodeCases(B, realPane);   // the same history on the second pair; only a difference makes a row
  quietPrefix = null;
  await accessLogParity(A, "A");
  await accessLogParity(B, "B");
  await wsParity(A, realPane);

  await federate(byName["bun-a"], byName["swift-a"], "A (bun issues, swift redeems)");
  await federate(byName["swift-b"], byName["bun-b"], "B (swift issues, bun redeems)");
  await reRedeem(byName["bun-a"], byName["swift-a"], "A");
  await reRedeem(byName["swift-b"], byName["bun-b"], "B");
  await crossFleet("issuers, bun-a vs swift-b", [byName["bun-a"], byName["swift-b"]], [byName["swift-a"], byName["bun-b"]], realPane);
  await crossFleet("joiners, bun-b vs swift-a", [byName["bun-b"], byName["swift-a"]], [byName["swift-b"], byName["bun-a"]], realPane);
  await crossPair("issuers, bun-a vs swift-b", [byName["bun-a"], byName["swift-b"]], [byName["swift-a"], byName["bun-b"]]);
  await crossPair("joiners, bun-b vs swift-a", [byName["bun-b"], byName["swift-a"]], [byName["swift-b"], byName["bun-a"]]);

  // strict mode: with FED_ALLOW_LEGACY=0 the members-only endpoints answer no one
  await compare(D, { name: "strict: GET /api/fed/state with no token (FED_ALLOW_LEGACY=0)", path: "/api/fed/state" });
  await compare(D, { name: "strict: POST /api/fed/ingest with no token", method: "POST", path: "/api/fed/ingest", body: { messages: [MSG] } });
  await federate(byName["swift-d"], byName["bun-d"], "D (swift issues, bun redeems, no herdr, FED_ALLOW_LEGACY=0)");
  await rebootPair(D, "D restarted, same state dirs");
  await compare(D, { name: "strict: GET /api/fed/state with no token, after the restart", path: "/api/fed/state" });

  // the kick, once with each runtime holding the knife
  await federate(byName["bun-f"], byName["swift-f"], "F (bun issues, swift redeems, strict)");
  await federate(byName["swift-g"], byName["bun-g"], "G (swift issues, bun redeems, strict)");
  await strictKick(byName["bun-f"], byName["swift-f"], "F (bun kicks swift)");
  await strictKick(byName["swift-g"], byName["bun-g"], "G (swift kicks bun)");
  await crossPair("kickers, bun-f vs swift-g", [byName["bun-f"], byName["swift-g"]], [byName["swift-f"], byName["bun-g"]]);
  await crossPair("kicked, bun-g vs swift-f", [byName["bun-g"], byName["swift-f"]], [byName["swift-g"], byName["bun-f"]]);

  // these kill the Bun side of a pair — last
  await transportCases(D, "missing socket", [byName["swift-d"], byName["bun-d"]]);
  if (haveStale) await transportCases([byName["bun-e"], byName["swift-e"]], "stale socket");
} finally {
  shutdown();
  // every port this run bound must come back, or the next run refuses to start
  const stuck: number[] = [];
  const deadline = Date.now() + 5000;
  for (const port of PORTS) {
    while (Date.now() < deadline && !(await portFree(port))) await Bun.sleep(100);
    if (!(await portFree(port))) stuck.push(port);
  }
  check("every port this run bound is free again", stuck.length === 0, stuck.length ? `still serving: ${stuck.join(", ")}` : `${PORTS.length} ports released`);
  report();
}
process.exit(failures === 0 ? 0 : 1);

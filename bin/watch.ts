#!/usr/bin/env bun
/**
 * Watch every agent the federation can reach, and print only what CHANGED.
 *
 * A poll that reprints the whole roster every tick buries the one line that
 * matters. This holds the previous snapshot and emits a line per transition:
 * an agent changing status, appearing, vanishing, or a node's link going down
 * and coming back. Quiet means nothing happened, which is the point.
 *
 *   bun bin/watch.ts                      # every 15s against 127.0.0.1:6750
 *   bun bin/watch.ts --every 30           # slower
 *   bun bin/watch.ts --peek white:w4:p1   # also dump that pane on every change
 *   HERDR_FED_URL=http://host:6750 bun bin/watch.ts
 */
const URL_BASE = process.env.HERDR_FED_URL ?? "http://127.0.0.1:6750";
const args = process.argv.slice(2);
const flag = (name: string) => {
  const i = args.indexOf(name);
  return i === -1 ? undefined : args[i + 1];
};
const EVERY = Math.max(Number(flag("--every") ?? 15), 3) * 1000;
// --peek may repeat: --peek white:w4:p1 --peek nm-white:w6:p1
const PEEKS = args.reduce<string[]>((acc, a, i) => (a === "--peek" && args[i + 1] ? [...acc, args[i + 1]] : acc), []);

type Row = { node: string; pane: string; handle: string; kind: string; status: string; via: string | null };

const clock = () => new Date().toTimeString().slice(0, 8);
const isAgent = (m: { kind?: string }) => !!m.kind && m.kind !== "shell";

async function snapshot(): Promise<{ rows: Map<string, Row>; links: Map<string, boolean> }> {
  const res = await fetch(`${URL_BASE}/api/status`, { signal: AbortSignal.timeout(8000) });
  if (!res.ok) throw new Error(`${res.status}`);
  const s = (await res.json()) as any;
  const relayed = s.relayed ?? {};
  const rows = new Map<string, Row>();
  const push = (node: string, m: any) => {
    if (!isAgent(m)) return;
    rows.set(`${node}:${m.pane}`, {
      node, pane: m.pane, handle: m.handle ?? m.pane, kind: m.kind, status: m.status ?? "unknown",
      via: relayed[node]?.via ?? null,
    });
  };
  for (const m of s.members ?? []) push(s.node, m);
  for (const [node, list] of Object.entries(s.peerMembers ?? {})) for (const m of (list as any[]) ?? []) push(node, m);
  // A link is "up" only when we hold it AND it is not failing; a relayed row
  // carries the hub's health, so it is reported under the hub, not on its own.
  const links = new Map<string, boolean>();
  for (const p of s.peers ?? []) if (!p.via) links.set(p.name, (p.consecutive ?? 0) === 0);
  return { rows, links };
}

async function peek(target: string) {
  const [node, ...rest] = target.split(":");
  const pane = rest.join(":");
  try {
    const res = await fetch(`${URL_BASE}/api/fleet/pane`, {
      method: "POST", headers: { "content-type": "application/json" },
      body: JSON.stringify({ node, pane, lines: 12 }), signal: AbortSignal.timeout(15000),
    });
    const out = (await res.json()) as { text?: string; error?: string };
    console.log(`  ── ${target} ──`);
    console.log((out.error ? `  ${out.error}` : (out.text ?? "").trimEnd()).replace(/^/gm, "  "));
  } catch (err) {
    console.log(`  ── ${target} ── unreadable: ${String(err).replace(/^Error:\s*/, "")}`);
  }
}

let prev: Awaited<ReturnType<typeof snapshot>> | null = null;
let down = false;

console.log(`[${clock()}] watching ${URL_BASE} every ${EVERY / 1000}s${PEEKS.length ? ` · peeking ${PEEKS.join(", ")}` : ""}`);

while (true) {
  try {
    const now = await snapshot();
    if (down) { console.log(`[${clock()}] node reachable again`); down = false; }

    if (prev) {
      const changes: string[] = [];
      for (const [key, r] of now.rows) {
        const before = prev.rows.get(key);
        const where = `${r.node}${r.via ? `(via ${r.via})` : ""}`;
        if (!before) changes.push(`+ ${where} ${r.handle} ${r.pane} ${r.kind} ${r.status}`);
        else if (before.status !== r.status) changes.push(`~ ${where} ${r.handle} ${before.status} → ${r.status}`);
      }
      for (const [key, r] of prev.rows) if (!now.rows.has(key)) changes.push(`- ${r.node} ${r.handle} ${r.pane} gone`);
      for (const [name, up] of now.links) {
        const was = prev.links.get(name);
        if (was !== undefined && was !== up) changes.push(`${up ? "↑" : "↓"} link ${name} ${up ? "recovered" : "FAILING"}`);
      }
      for (const [name] of prev.links) if (!now.links.has(name)) changes.push(`- peer ${name} dropped`);

      if (changes.length) {
        for (const c of changes) console.log(`[${clock()}] ${c}`);
        for (const t of PEEKS) await peek(t);
      }
    } else {
      const agents = now.rows.size;
      const nodes = new Set([...now.rows.values()].map((r) => r.node)).size;
      console.log(`[${clock()}] baseline: ${agents} agents across ${nodes} nodes · ${now.links.size} direct links`);
    }
    prev = now;
  } catch (err) {
    if (!down) { console.log(`[${clock()}] node unreachable: ${String(err).replace(/^Error:\s*/, "")}`); down = true; }
    // Do NOT clear `prev`: when it comes back, the diff against the last known
    // good state is exactly the report worth having.
  }
  await Bun.sleep(EVERY);
}

import { useState } from "react";
import type { AdminState, FedEdge, KnownNode, Member } from "../../types";

/**
 * The federation, drawn.
 *
 * Every relationship here has TWO halves, because enforcement in this service is
 * local-only: a kick binds the node that issued it, so "we hold them" and "they
 * report holding us" are separate facts. A single undirected line between two
 * nodes would hide exactly the state a person needs, so each edge carries its
 * own direction — and, when the link is failing, an explicit admission that what
 * the far side reports arrived on the last successful pull and may no longer be
 * true.
 *
 * The geometry is deliberately fixed rather than force-directed: this node in the
 * middle, peers on a ring. A layout that moves as data arrives makes a poll feel
 * like an event, and there is never a fleet large enough here to need clustering.
 */

const R = 150;        // ring radius
const SIZE = 420;     // viewBox is square; the ring is centred in it
const C = SIZE / 2;

type Placed = { edge?: FedEdge; heard?: KnownNode; x: number; y: number; label: string };

const DOT: Record<string, string> = {
  working: "text-ok",
  blocked: "text-bad",
  done: "text-accent",
  idle: "text-faint",
};

/** The agents on one node, grouped by workspace the way the console's sidebar is. */
function Agents({ panes, empty }: { panes: Member[]; empty: string }) {
  // `kind` is the pane's agent, or "shell" when herdr detected none. A bare shell
  // is a pane, not an agent, and listing it under "agents on m5" is simply wrong —
  // the count beside a node is agents too, so the two must filter identically.
  const agents = panes.filter((p) => p.kind && p.kind !== "shell");
  if (!agents.length) return <div className="text-[11px] text-faint">{empty}</div>;
  const byWorkspace = new Map<string, Member[]>();
  for (const p of agents) {
    const k = p.workspaceLabel ?? p.workspace ?? "—";
    byWorkspace.set(k, [...(byWorkspace.get(k) ?? []), p]);
  }
  return (
    <div className="grid gap-1">
      {[...byWorkspace].map(([ws, list]) => (
        <div key={ws} className="grid grid-cols-[minmax(0,1fr)_auto] gap-2 text-[11px]">
          <span className="truncate text-dim">{ws}</span>
          <span className="flex flex-wrap justify-end gap-1.5 text-faint">
            {list.map((p) => (
              <span key={p.pane} title={`${p.pane}${p.where ? ` · ${p.where}` : ""}`}>
                <span className={DOT[p.status ?? "idle"] ?? "text-faint"}>●</span> {p.kind}
              </span>
            ))}
          </span>
        </div>
      ))}
    </div>
  );
}

const ago = (iso?: string) => {
  if (!iso) return "never";
  const s = Math.round((Date.now() - Date.parse(iso)) / 1000);
  if (!Number.isFinite(s)) return "never";
  if (s < 60) return `${Math.max(s, 0)}s ago`;
  if (s < 3600) return `${Math.round(s / 60)}m ago`;
  if (s < 86400) return `${Math.round(s / 3600)}h ago`;
  return `${Math.round(s / 86400)}d ago`;
};

/** ⇄ mutual · → we hold them · ← they hold us · ·· neither · ⇠⇢ stale */
function glyph(e: FedEdge) {
  if (e.stale) return "⇠⇢";
  if (e.mutual) return "⇄";
  if (e.ours) return "→";
  if (e.theirs) return "←";
  return "··";
}

function tone(e?: FedEdge) {
  if (!e) return "var(--color-live)";            // heard from, never joined
  if (e.stale) return "var(--color-warn)";
  if (e.mutual) return "var(--color-ok)";
  if (e.ours || e.theirs) return "var(--color-warn)";
  return "var(--color-bad)";
}

function why(e: FedEdge) {
  if (e.stale)
    return `Stale. Everything this peer reports arrived on the last successful pull, ${ago(e.lastOkAt)}. ${e.peer} may have dropped us since — ${e.consecutive} attempt${e.consecutive === 1 ? "" : "s"} have failed.`;
  if (e.mutual) return `Mutual. Both nodes hold each other as a member.`;
  if (e.ours) return `One-way. We hold ${e.peer} as a member; ${e.peer} does not report holding us.`;
  if (e.theirs) return `One-way. ${e.peer} reports holding us; we do not hold them — they can reach us, we cannot act on them.`;
  return `Neither side reports the other as a member.`;
}

export function MeshMap({ state }: { state: AdminState }) {
  const [picked, setPicked] = useState<string | null>(null);

  const edges = state.edges ?? [];
  const heard = state.heard ?? [];
  const around: Placed[] = [...edges.map((e) => ({ edge: e, label: e.peer })), ...heard.map((k) => ({ heard: k, label: k.node }))]
    .map((n, i, all) => {
      // start at the top and go clockwise; a single peer sits directly above
      const angle = (i / Math.max(all.length, 1)) * Math.PI * 2 - Math.PI / 2;
      return { ...n, x: C + Math.cos(angle) * R, y: C + Math.sin(angle) * R };
    });

  const sel = around.find((n) => n.label === picked);
  const mutual = edges.filter((e) => e.mutual).length;
  const stale = edges.filter((e) => e.stale).length;

  return (
    <div className="grid gap-4 lg:grid-cols-[minmax(0,420px)_1fr]">
      <section className="rounded-lg border border-edge bg-panel p-2">
        <svg viewBox={`0 0 ${SIZE} ${SIZE}`} className="h-auto w-full" role="img" aria-label="federation map">
          {around.map((n) => {
            const t = tone(n.edge);
            const e = n.edge;
            return (
              <g key={n.label}>
                <line
                  x1={C} y1={C} x2={n.x} y2={n.y}
                  stroke={t}
                  strokeWidth={n.label === picked ? 2.5 : 1.5}
                  strokeDasharray={e?.stale || !e ? "5 4" : undefined}
                  opacity={e ? 0.85 : 0.5}
                />
                {/* the arrow sits on the line rather than at a node, so which way
                    the relationship runs is readable without hovering */}
                <text
                  x={(C + n.x) / 2} y={(C + n.y) / 2 - 5}
                  textAnchor="middle" fill={t}
                  className="font-mono text-[15px]"
                >
                  {e ? glyph(e) : "··"}
                </text>
              </g>
            );
          })}

          <circle cx={C} cy={C} r={30} fill="var(--color-panel)" stroke="var(--color-accent)" strokeWidth={2} />
          <text x={C} y={C - 2} textAnchor="middle" fill="var(--color-fg)" className="font-mono text-[12px] font-semibold">
            {state.node}
          </text>
          <text x={C} y={C + 12} textAnchor="middle" fill="var(--color-faint)" className="font-mono text-[9px]">
            this node
          </text>

          {around.map((n) => (
            <g key={n.label} onClick={() => setPicked(n.label === picked ? null : n.label)} className="cursor-pointer">
              <circle
                cx={n.x} cy={n.y} r={26}
                fill="var(--color-panel)"
                stroke={tone(n.edge)}
                strokeWidth={n.label === picked ? 2.5 : 1.5}
                strokeDasharray={n.edge ? undefined : "4 3"}
              />
              <text x={n.x} y={n.y - 1} textAnchor="middle" fill="var(--color-fg)" className="font-mono text-[10px]">
                {n.label.length > 9 ? `${n.label.slice(0, 8)}…` : n.label}
              </text>
              <text x={n.x} y={n.y + 11} textAnchor="middle" fill="var(--color-faint)" className="font-mono text-[9px]">
                {n.edge ? `${n.edge.panes} agents` : "heard"}
              </text>
            </g>
          ))}
        </svg>

        <div className="flex flex-wrap gap-x-3 gap-y-1 px-2 pb-1 text-[11px] text-faint">
          <span><span className="text-ok">⇄</span> mutual</span>
          <span><span className="text-warn">→</span> we hold them</span>
          <span><span className="text-warn">←</span> they hold us</span>
          <span><span className="text-warn">⇠⇢</span> stale</span>
          <span><span className="text-live">··</span> heard, never joined</span>
        </div>
      </section>

      <section className="min-w-0 rounded-lg border border-edge bg-panel">
        <header className="flex flex-wrap items-baseline gap-2 border-b border-edge px-3 py-2">
          <b className="font-semibold">{sel ? sel.label : "the mesh"}</b>
          <span className="text-[11px] text-faint">
            {sel ? "click the node again to go back" : `${mutual}/${edges.length} mutual${stale ? ` · ${stale} stale` : ""} · ${heard.length} heard`}
          </span>
        </header>

        {!sel && (
          <div className="grid gap-3 px-3 py-3">
            <div>
              <div className="pb-1 text-[11px] tracking-[.08em] text-faint">agents on {state.node} — this node</div>
              <Agents panes={state.panes ?? []} empty="no agent panes here" />
            </div>
            {(state.edges ?? []).map((e) => (
              <div key={e.peer}>
                <div className="pb-1 text-[11px] tracking-[.08em] text-faint">
                  agents on {e.peer}
                  {e.stale && <span className="text-warn"> · stale, from the last successful pull</span>}
                </div>
                <Agents panes={state.peerPanes?.[e.peer] ?? []} empty="nothing published" />
              </div>
            ))}
          </div>
        )}

        {!sel && (
          <div className="border-t border-edge px-3 py-3 text-[11px] leading-relaxed text-dim">
            <p>
              Each line is one relationship, and it has two halves. This node holding a peer, and that peer
              reporting it holds us, are separate facts — enforcement here is <b className="text-fg">local only</b>,
              so a kick binds whichever node issued it and nothing propagates on its own.
            </p>
            <p className="pt-2">
              A <span className="text-warn">dashed</span> line means the link is failing, so what that peer
              reports came from the last successful pull. It can claim a mutuality that no longer exists —
              which is why it is drawn differently rather than simply shown.
            </p>
            <p className="pt-2 text-faint">Click a node for its detail.</p>
          </div>
        )}

        {sel?.edge && (
          <div className="grid gap-1.5 px-3 py-3 text-[11px]">
            <div className="text-dim">{why(sel.edge)}</div>
            <div className="truncate text-faint">{sel.edge.url}</div>
            <div className="text-faint">
              {sel.edge.panes} pane{sel.edge.panes === 1 ? "" : "s"} · seen {ago(sel.edge.lastSeen)} · last ok {ago(sel.edge.lastOkAt)}
            </div>
            {!!sel.edge.consecutive && (
              <div className="text-bad">
                {sel.edge.consecutive} failed attempt{sel.edge.consecutive === 1 ? "" : "s"} since the last success
                {sel.edge.lastError ? ` — ${sel.edge.lastError}` : ""}
              </div>
            )}
            <div className="pt-1 text-faint">
              they federate with:{" "}
              {(state.meshMembers?.[sel.label] ?? []).map((m) => m.node).join(", ") || "nothing reported"}
              {sel.edge.stale && <span className="text-warn"> (stale)</span>}
            </div>
            <div className="border-t border-edge pt-2">
              <div className="pb-1 text-[11px] tracking-[.08em] text-faint">
                agents on {sel.label}
                {sel.edge.stale && <span className="text-warn"> · stale</span>}
              </div>
              <Agents panes={state.peerPanes?.[sel.label] ?? []} empty="nothing published" />
            </div>
          </div>
        )}

        {sel?.heard && (
          <div className="grid gap-1.5 px-3 py-3 text-[11px]">
            <div className="text-dim">
              This node reached us but has never joined. We hold no membership for it, so nothing here can act on it.
            </div>
            <div className="truncate text-faint">{sel.heard.url ?? "address unknown — it reached us"}</div>
            <div className="text-faint">heard {ago(sel.heard.lastHeard)}</div>
          </div>
        )}
      </section>
    </div>
  );
}

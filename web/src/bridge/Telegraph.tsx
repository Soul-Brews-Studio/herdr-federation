import type { FedEdge } from "../types";

/**
 * An engine-order telegraph, which is what a federation edge actually is.
 *
 * You ring an order; the far end rings an answer back. The two needles are
 * independent, and that independence is the product's hardest truth: "we hold
 * them" and "they report holding us" are separate facts, because enforcement
 * here is local-only and a kick binds whichever node issued it. A single needle
 * — one line between two nodes — would be the lie this whole console exists to
 * avoid telling.
 *
 * The answer needle also goes GHOSTED when the link is failing, because what the
 * far side reports only arrived on the last successful pull. A telegraph whose
 * answer needle is stuck at its last position, presented as current, is exactly
 * the instrument you cannot trust in the dark.
 */

const R = 46;
const CX = 60;
const CY = 60;

/** -120°..+120° across the face; the needle sweeps the same arc as the engraving. */
function hand(deg: number, len: number) {
  const rad = ((deg - 90) * Math.PI) / 180;
  return { x: CX + Math.cos(rad) * len, y: CY + Math.sin(rad) * len };
}

const POSITIONS = [
  { deg: -120, label: "STOP" },
  { deg: -60, label: "SLOW" },
  { deg: 0, label: "HALF" },
  { deg: 60, label: "FULL" },
  { deg: 120, label: "OVER" },
];

/** Where the order needle sits: how hard this node is driving the link. */
function orderDeg(e: FedEdge): number {
  if (!e.ours) return -120;
  const fails = e.consecutive ?? 0;
  if (fails === 0) return 60;
  if (fails < 3) return 0;
  return -60;
}

/** Where the answer needle sits: what came back, if anything did. */
function answerDeg(e: FedEdge): number {
  if (!e.theirs) return -120;
  return e.stale ? 0 : 60;
}

export function Telegraph({ edge, panes }: { edge: FedEdge; panes: number }) {
  const order = orderDeg(edge);
  const answer = answerDeg(edge);
  const alarm = (edge.consecutive ?? 0) > 0;
  const agreed = edge.mutual;

  const o = hand(order, R - 12);
  const a = hand(answer, R - 20);

  return (
    <figure className="plate flex flex-col items-center px-3 pb-3 pt-2">
      <svg viewBox="0 0 120 120" className="h-[120px] w-[120px]" role="img"
           aria-label={`${edge.peer}: order ${edge.ours ? "engaged" : "stop"}, answer ${edge.theirs ? (edge.stale ? "stale" : "engaged") : "none"}`}>
        {/* bezel */}
        <circle cx={CX} cy={CY} r={R + 7} fill="none" stroke="var(--color-brass-dim)" strokeWidth="2" />
        <circle cx={CX} cy={CY} r={R + 4} fill="none" stroke="var(--color-brass)" strokeWidth="1" />
        {/* dial face — the lit object */}
        <circle cx={CX} cy={CY} r={R} fill="var(--color-bone)" />
        <circle cx={CX} cy={CY} r={R} fill="none" stroke="#000" strokeOpacity="0.25" strokeWidth="1" />

        {/* engraved detents */}
        {POSITIONS.map((p) => {
          const outer = hand(p.deg, R - 3);
          const inner = hand(p.deg, R - 10);
          const text = hand(p.deg, R - 20);
          return (
            <g key={p.label}>
              <line x1={outer.x} y1={outer.y} x2={inner.x} y2={inner.y} stroke="#3a3428" strokeWidth="1.5" />
              <text x={text.x} y={text.y + 2.5} textAnchor="middle"
                    fill="#5d5442" fontSize="6.5" fontFamily="Archivo Narrow, sans-serif"
                    fontWeight="700" letterSpacing="0.5">{p.label}</text>
            </g>
          );
        })}

        {/* answer needle — behind, thinner, ghosted when the report is stale */}
        <line x1={CX} y1={CY} x2={a.x} y2={a.y}
              stroke={edge.theirs ? "var(--color-answer)" : "#9a927f"}
              strokeWidth="2.5" strokeLinecap="round"
              strokeDasharray={edge.stale ? "3 3" : undefined}
              opacity={edge.stale ? 0.55 : 1} />

        {/* order needle — ours, in front */}
        <line x1={CX} y1={CY} x2={o.x} y2={o.y}
              stroke={alarm ? "var(--color-alarm)" : "var(--color-order)"}
              strokeWidth="3.5" strokeLinecap="round" />

        <circle cx={CX} cy={CY} r={5} fill="var(--color-brass)" stroke="#2b2318" strokeWidth="1" />
      </svg>

      <figcaption className="mt-1 w-full text-center">
        <div className="engrave text-[12px] leading-tight">{edge.peer}</div>
        <div className="text-[11px] text-bone-dim">
          {agreed ? "order answered" : edge.stale ? "answer is stale" : edge.ours ? "no answer" : edge.theirs ? "answering us" : "silent"}
        </div>
        <div className="text-[11px] text-bone-dim">
          {panes} agent{panes === 1 ? "" : "s"}
          {(edge.consecutive ?? 0) > 0 ? ` · ${edge.consecutive} missed` : ""}
        </div>
      </figcaption>
    </figure>
  );
}

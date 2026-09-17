import type { Member } from "../types";

/**
 * The watch board: who is on duty, on which machine, doing what.
 *
 * A ship's watch board is a nameplate per station and a lamp per station, read
 * from across the room without stopping. That is the right instrument for
 * "which of thirty agents needs me", and it is why this is a board of stations
 * rather than a grid of cards.
 *
 * Lamps are drawn, not typed. A filled circle glyph is a character in a font;
 * it cannot carry a bloom, and it renders differently on every platform.
 */

const LAMP: Record<string, { fill: string; glow: number; label: string }> = {
  working: { fill: "var(--color-order)", glow: 0.55, label: "working" },
  blocked: { fill: "var(--color-alarm)", glow: 0.65, label: "blocked" },
  done: { fill: "var(--color-answer)", glow: 0.35, label: "done" },
  idle: { fill: "var(--color-idle)", glow: 0, label: "idle" },
};

function Lamp({ status, title }: { status?: string; title: string }) {
  const l = LAMP[status ?? "idle"] ?? LAMP.idle;
  return (
    <svg viewBox="0 0 14 14" className="h-3.5 w-3.5 shrink-0" role="img" aria-label={`${title}: ${l.label}`}>
      <title>{`${title} — ${l.label}`}</title>
      {l.glow > 0 && <circle cx="7" cy="7" r="6" fill={l.fill} opacity={l.glow * 0.3} />}
      <circle cx="7" cy="7" r="3.4" fill={l.fill} />
      <circle cx="7" cy="7" r="3.4" fill="none" stroke="#000" strokeOpacity="0.45" strokeWidth="1" />
      {/* the filament highlight — a lamp is lit from inside */}
      {l.glow > 0 && <circle cx="5.9" cy="5.9" r="1" fill="#fff" opacity="0.5" />}
    </svg>
  );
}

type Station = { machine: string; workspace: string; agents: Member[] };

export function WatchBoard({
  stations,
  onPick,
  selected,
}: {
  stations: Station[];
  onPick: (m: Member, machine: string) => void;
  selected?: string;
}) {
  if (!stations.length) {
    return (
      <div className="px-4 py-6 text-[12px] text-bone-dim">
        No agent is on watch. Start one in herdr and it appears here within the poll.
      </div>
    );
  }
  let machine = "";
  return (
    <div>
      {stations.map((s) => {
        const newMachine = s.machine !== machine;
        machine = s.machine;
        return (
          <section key={`${s.machine}/${s.workspace}`}>
            {newMachine && (
              <h2 className="engrave sticky top-0 z-10 border-y border-seam bg-iron-deep px-4 py-1.5 text-[12px]">
                {s.machine}
              </h2>
            )}
            <div className="grid grid-cols-[minmax(0,1fr)_auto] items-baseline gap-2 px-4 pt-2.5 pb-1">
              <span className="truncate text-[12px] text-bone-dim">{s.workspace}</span>
              <span className="text-[11px] text-bone-dim">{s.agents.length}</span>
            </div>
            <ul className="pb-1">
              {s.agents.map((a) => {
                const on = selected === `${s.machine}/${a.pane}`;
                return (
                  <li key={a.pane}>
                    <button
                      onClick={() => onPick(a, s.machine)}
                      aria-current={on ? "true" : undefined}
                      className={`grid w-full grid-cols-[auto_minmax(0,1fr)_auto] items-center gap-2.5 px-4 py-1.5 text-left transition-colors duration-150 ${
                        on ? "bg-plate" : "hover:bg-plate/60"
                      }`}
                    >
                      <Lamp status={a.status} title={a.handle} />
                      <span className="truncate text-[12px]">{a.handle}</span>
                      <span className="text-[11px] text-bone-dim">{a.kind}</span>
                    </button>
                  </li>
                );
              })}
            </ul>
          </section>
        );
      })}
    </div>
  );
}

export type { Station };

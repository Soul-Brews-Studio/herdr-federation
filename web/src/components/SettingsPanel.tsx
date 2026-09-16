import { useEffect } from "react";
import { DEFAULTS, resetSettings, useSettings, type Settings } from "../settings";
import { X } from "./Icons";

type Props = { onClose: () => void };

const Row = ({ label, hint, children }: { label: string; hint?: string; children: React.ReactNode }) => (
  <div className="grid grid-cols-[1fr_auto] items-center gap-4 border-b border-edge px-4 py-2.5 last:border-b-0">
    <div className="min-w-0">
      <div>{label}</div>
      {hint && <div className="text-[11px] text-faint">{hint}</div>}
    </div>
    <div className="flex items-center gap-1">{children}</div>
  </div>
);

function Choice<K extends keyof Settings>({
  name,
  value,
  options,
  onPick,
}: {
  name: K;
  value: Settings[K];
  options: { v: Settings[K]; label: string }[];
  onPick: (patch: Partial<Settings>) => void;
}) {
  return (
    <>
      {options.map((o) => (
        <button
          key={String(o.v)}
          onClick={() => onPick({ [name]: o.v } as Partial<Settings>)}
          className={`rounded px-2.5 py-1 text-[11px] ${
            value === o.v ? "bg-[#1d2532] text-accent" : "text-faint hover:bg-[#161b24] hover:text-dim"
          }`}
        >
          {o.label}
        </button>
      ))}
    </>
  );
}

const Stepper = ({ value, set, min, max, step = 1, unit = "" }: {
  value: number; set: (n: number) => void; min: number; max: number; step?: number; unit?: string;
}) => (
  <>
    <button onClick={() => set(Math.max(min, value - step))} className="grid h-6 w-6 place-items-center rounded text-faint hover:bg-[#1f2531] hover:text-fg">−</button>
    <span className="w-14 text-center text-[11px] text-dim">{value}{unit}</span>
    <button onClick={() => set(Math.min(max, value + step))} className="grid h-6 w-6 place-items-center rounded text-faint hover:bg-[#1f2531] hover:text-fg">+</button>
  </>
);

/** ⌘, — the console's own preferences, stored per browser. */
export function SettingsPanel({ onClose }: Props) {
  const [s, set] = useSettings();

  useEffect(() => {
    const onKey = (e: KeyboardEvent) => e.key === "Escape" && onClose();
    addEventListener("keydown", onKey);
    return () => removeEventListener("keydown", onKey);
  }, [onClose]);

  return (
    <div className="fixed inset-0 z-50 grid place-items-start justify-center bg-[#05070ad0] pt-[9vh]" onClick={onClose}>
      <div
        onClick={(e) => e.stopPropagation()}
        className="w-[min(94vw,620px)] overflow-hidden rounded-lg border border-edge-bright bg-panel shadow-[0_24px_60px_-24px_rgba(0,0,0,.95)]"
      >
        <div className="flex items-baseline gap-2.5 border-b border-edge px-4 py-3">
          <b className="font-semibold">settings</b>
          <span className="text-[11px] text-faint">this browser only · ⌘,</span>
          <button onClick={onClose} className="ml-auto text-faint hover:text-fg">
            <X className="h-3.5 w-3.5" />
          </button>
        </div>

        <Row label="clicking an agent" hint="the tab row lives inside this page; a window is a real browser tab">
          <Choice
            name="openIn"
            value={s.openIn}
            onPick={set}
            options={[
              { v: "tab", label: "new tab" },
              { v: "replace", label: "replace" },
              { v: "window", label: "browser tab" },
            ]}
          />
        </Row>

        <Row label="renderer for a new pane" hint="terminal is xterm.js with real colour; text is a lighter mirror">
          <Choice
            name="render"
            value={s.render}
            onPick={set}
            options={[
              { v: "text", label: "text" },
              { v: "terminal", label: "terminal" },
            ]}
          />
        </Row>

        <Row label="typing in text mode" hint="terminal mode always types; this is for the plain mirror">
          <Choice
            name="typeInText"
            value={s.typeInText}
            onPick={set}
            options={[
              { v: false, label: "read-only" },
              { v: true, label: "allow" },
            ]}
          />
        </Row>

        <Row label="pane type size" hint="full pane / squad tile">
          <Stepper value={s.zoom} set={(n) => set({ zoom: n })} min={6} max={24} unit="px" />
          <span className="px-1 text-[#333a46]">/</span>
          <Stepper value={s.zoomDense} set={(n) => set({ zoomDense: n })} min={6} max={24} unit="px" />
        </Row>

        <Row label="bottom rail" hint="federation messages and the herdr call log">
          <Choice
            name="showRail"
            value={s.showRail}
            onPick={set}
            options={[
              { v: true, label: "show" },
              { v: false, label: "hide" },
            ]}
          />
        </Row>

        <Row label="refresh interval" hint="how often this console asks its node for state">
          <Stepper value={s.pollMs} set={(n) => set({ pollMs: n })} min={500} max={10000} step={500} unit="ms" />
        </Row>

        <div className="flex items-center gap-3 border-t border-edge bg-[#0f1218] px-4 py-2.5 text-[11px]">
          <span className="text-faint">
            defaults: {DEFAULTS.openIn} · {DEFAULTS.render} · {DEFAULTS.pollMs}ms
          </span>
          <button onClick={resetSettings} className="ml-auto text-faint hover:text-accent">
            reset to defaults
          </button>
        </div>
      </div>
    </div>
  );
}

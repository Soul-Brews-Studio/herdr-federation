/** Small form pieces shared by the settings modal and the admin page. */

export const Row = ({ label, hint, children }: { label: string; hint?: string; children: React.ReactNode }) => (
  <div className="grid grid-cols-[1fr_auto] items-center gap-4 border-b border-edge px-4 py-2.5 last:border-b-0">
    <div className="min-w-0">
      <div>{label}</div>
      {hint && <div className="text-[11px] text-faint">{hint}</div>}
    </div>
    <div className="flex items-center gap-1">{children}</div>
  </div>
);

export const Stepper = ({ value, set, min, max, step = 1, unit = "" }: {
  value: number; set: (n: number) => void; min: number; max: number; step?: number; unit?: string;
}) => (
  <>
    <button onClick={() => set(Math.max(min, value - step))} className="grid h-6 w-6 place-items-center rounded text-faint hover:bg-[#1f2531] hover:text-fg">−</button>
    <span className="w-14 text-center text-[11px] text-dim">{value}{unit}</span>
    <button onClick={() => set(Math.min(max, value + step))} className="grid h-6 w-6 place-items-center rounded text-faint hover:bg-[#1f2531] hover:text-fg">+</button>
  </>
);

/** A row of mutually exclusive choices, the console's stand-in for a radio group. */
export function Pick<T extends string | number | boolean>({ value, options, onPick }: {
  value: T; options: { v: T; label: string }[]; onPick: (v: T) => void;
}) {
  return (
    <>
      {options.map((o) => (
        <button
          key={String(o.v)}
          onClick={() => onPick(o.v)}
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

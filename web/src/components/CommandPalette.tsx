import { useEffect, useMemo, useRef, useState } from "react";
import type { Located, Status } from "../types";
import { allMembers, place } from "../lib";
import { StatusGlyph } from "./Icons";

type Props = {
  status: Status | null;
  onPick: (m: Located, interactive: boolean) => void;
};

/** subsequence match, so "nehe" finds "neo-herdr" */
function score(needle: string, hay: string) {
  if (!needle) return 0;
  const h = hay.toLowerCase();
  let i = 0;
  let hits = 0;
  for (const ch of needle.toLowerCase()) {
    const at = h.indexOf(ch, i);
    if (at === -1) return -1;
    if (at === i) hits++;
    i = at + 1;
  }
  return hits * 2 + (h.startsWith(needle.toLowerCase()) ? 10 : 0);
}

/**
 * ⌘K — every pane on every node in the federation, one keystroke away.
 * Enter watches it, ⇧Enter (or ⌘Enter) opens it for typing.
 */
export function CommandPalette({ status, onPick }: Props) {
  const [open, setOpen] = useState(false);
  const [q, setQ] = useState("");
  const [cursor, setCursor] = useState(0);
  const input = useRef<HTMLInputElement>(null);

  useEffect(() => {
    const onKey = (e: KeyboardEvent) => {
      if ((e.metaKey || e.ctrlKey) && e.key.toLowerCase() === "k") {
        e.preventDefault();
        setOpen((v) => !v);
        setQ("");
        setCursor(0);
      } else if (e.key === "Escape") {
        setOpen(false);
      }
    };
    addEventListener("keydown", onKey);
    return () => removeEventListener("keydown", onKey);
  }, []);

  useEffect(() => {
    if (open) setTimeout(() => input.current?.focus(), 0);
  }, [open]);

  const hits = useMemo(() => {
    const all = allMembers(status);
    if (!q.trim()) return all.slice(0, 40);
    return all
      .map((m) => ({ m, s: Math.max(score(q, m.handle), score(q, `${m.node} ${m.repo ?? place(m.where).repo}`)) }))
      .filter((x) => x.s >= 0)
      .sort((a, b) => b.s - a.s)
      .slice(0, 40)
      .map((x) => x.m);
  }, [q, status]);

  if (!open) return null;

  const choose = (m: Located, interactive: boolean) => {
    onPick(m, interactive);
    setOpen(false);
  };

  return (
    <div
      className="fixed inset-0 z-50 grid place-items-start justify-center bg-[#05070ad0] pt-[12vh] backdrop-blur-[2px]"
      onClick={() => setOpen(false)}
    >
      <div
        onClick={(e) => e.stopPropagation()}
        className="w-[min(92vw,640px)] overflow-hidden rounded-lg border border-edge-bright bg-panel shadow-[0_24px_60px_-24px_rgba(0,0,0,.95)]"
      >
        <input
          ref={input}
          value={q}
          onChange={(e) => {
            setQ(e.target.value);
            setCursor(0);
          }}
          onKeyDown={(e) => {
            if (e.key === "ArrowDown") {
              e.preventDefault();
              setCursor((c) => Math.min(hits.length - 1, c + 1));
            } else if (e.key === "ArrowUp") {
              e.preventDefault();
              setCursor((c) => Math.max(0, c - 1));
            } else if (e.key === "Enter" && hits[cursor]) {
              e.preventDefault();
              choose(hits[cursor], e.shiftKey || e.metaKey);
            }
          }}
          placeholder="find an oracle, anywhere in the federation"
          aria-label="find an agent"
          className="w-full border-0 bg-transparent px-4 py-3.5 text-fg outline-none placeholder:text-[#545c6a]"
        />

        <div className="max-h-[52vh] overflow-y-auto border-t border-edge">
          {hits.length === 0 && <div className="px-4 py-3 text-[11px] text-faint">nothing matches</div>}
          {hits.map((m, i) => (
            <button
              key={`${m.node}/${m.pane}`}
              onMouseEnter={() => setCursor(i)}
              onClick={(e) => choose(m, e.shiftKey || e.metaKey)}
              className={`grid w-full grid-cols-[14px_minmax(0,1fr)_auto] items-center gap-2.5 px-4 py-1.5 text-left ${
                i === cursor ? "bg-[#18212e]" : ""
              }`}
            >
              <StatusGlyph status={m.status} className="w-[11px] h-[11px]" />
              <span className="truncate">{m.handle}</span>
              <span className="flex items-center gap-2 text-[11px] text-faint">
                <span>{m.repo ?? place(m.where).repo}</span>
                <span className={m.node === status?.node ? "text-accent" : "text-live"}>{m.node}</span>
              </span>
            </button>
          ))}
        </div>

        <div className="flex gap-3.5 border-t border-edge px-4 py-2 text-[11px] text-faint">
          <span>↵ watch</span>
          <span>⇧↵ take control</span>
          <span className="ml-auto">esc to close</span>
        </div>
      </div>
    </div>
  );
}

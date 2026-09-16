import { useEffect, useRef, useState } from "react";
import { api } from "../api";
import type { Located } from "../types";
import { Control, Send, Watch } from "./Icons";

export type MenuTarget = { member: Located; x: number; y: number };

type Props = {
  target: MenuTarget | null;
  onClose: () => void;
  onWatch: (m: Located) => void;
  onControl: (m: Located) => void;
  /** squads page only */
  onAddToSquad?: (m: Located) => void;
};

/**
 * One menu for every agent row, on both pages: watch it, take it over, say
 * something to it, or copy the command line that would do the same by hand.
 */
export function AgentMenu({ target, onClose, onWatch, onControl, onAddToSquad }: Props) {
  const [text, setText] = useState("");
  const [note, setNote] = useState<string | null>(null);
  const box = useRef<HTMLDivElement>(null);

  useEffect(() => {
    setText("");
    setNote(null);
  }, [target?.member.pane]);

  useEffect(() => {
    if (!target) return;
    const onKey = (e: KeyboardEvent) => e.key === "Escape" && onClose();
    const onDown = (e: MouseEvent) => {
      if (!box.current?.contains(e.target as Node)) onClose();
    };
    addEventListener("keydown", onKey);
    addEventListener("mousedown", onDown);
    return () => {
      removeEventListener("keydown", onKey);
      removeEventListener("mousedown", onDown);
    };
  }, [target, onClose]);

  if (!target) return null;
  const { member: m, x, y } = target;
  const remote = !!m.base;

  async function hey(e: React.FormEvent) {
    e.preventDefault();
    if (!text.trim()) return;
    try {
      await api.hey(m.pane, text, m.base);
      setNote(`sent to ${m.handle}`);
      setText("");
      setTimeout(onClose, 700);
    } catch (err) {
      setNote((err as Error).message);
    }
  }

  const copy = (s: string, label: string) => {
    void navigator.clipboard.writeText(s);
    setNote(`copied ${label}`);
  };

  const item = "flex w-full items-center gap-2.5 px-3 py-1.5 text-left hover:bg-[#1b2230]";

  return (
    <div
      ref={box}
      style={{ left: Math.min(x, innerWidth - 300), top: Math.min(y, innerHeight - 280) }}
      className="fixed z-50 w-[288px] overflow-hidden rounded-lg border border-edge-bright bg-panel shadow-[0_18px_44px_-20px_rgba(0,0,0,.95)]"
    >
      <div className="border-b border-edge px-3 py-2">
        <div className="truncate">{m.handle}</div>
        <div className="truncate text-[11px] text-faint">
          {m.kind} · {m.pane} · {m.node}
        </div>
      </div>

      <button className={item} onClick={() => (onWatch(m), onClose())}>
        <Watch className="w-[13px] h-[13px] text-faint" />
        watch
      </button>
      <button className={item} onClick={() => (onControl(m), onClose())}>
        <Control className="w-[13px] h-[13px] text-faint" />
        take control
      </button>
      <button
        className={item}
        onClick={() => {
          window.open(`/t/${encodeURIComponent(m.node)}/${encodeURIComponent(m.pane)}/ro`, "_blank", "noopener");
          onClose();
        }}
      >
        <span className="w-[13px] text-center text-faint">↗</span>
        open in a browser tab
      </button>
      {onAddToSquad && (
        <button className={item} onClick={() => (onAddToSquad(m), onClose())}>
          <span className="w-[13px] text-center text-faint">+</span>
          add to squad
        </button>
      )}

      <form onSubmit={hey} className="grid grid-cols-[1fr_auto] gap-2 border-t border-edge p-2.5">
        <input
          autoFocus
          value={text}
          onChange={(e) => setText(e.target.value)}
          placeholder={`hey ${m.handle.slice(0, 16)}…`}
          aria-label="message this agent"
          className="min-w-0 rounded-md border border-edge-bright bg-[#0b0e13] px-2 py-1.5 placeholder:text-[#545c6a]"
        />
        <button type="submit" className="rounded-md bg-accent px-2.5 text-[#07131d] hover:bg-[#7cc3ff]" title="send">
          <Send className="w-[13px] h-[13px]" />
        </button>
      </form>

      <div className="grid border-t border-edge text-[11px]">
        <button className={item} onClick={() => copy(m.pane, "pane id")}>
          copy pane id
        </button>
        <button
          className={item}
          onClick={() => copy(`herdr agent prompt ${m.pane} "${text || "…"}"`, "cli")}
          title="the same thing, by hand"
        >
          copy herdr cli
        </button>
      </div>

      {(note || remote) && (
        <div className="border-t border-edge px-3 py-1.5 text-[11px] text-faint">
          {note ?? `runs on ${m.node}`}
        </div>
      )}
    </div>
  );
}

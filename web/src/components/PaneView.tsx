import { useEffect, useRef, useState } from "react";
import type { Located, PaneServerMessage } from "../types";
import { useSettings } from "../settings";

type Props = {
  member: Located;
  /** typing is opt-in; watching never sends a byte */
  interactive?: boolean;
  /** shrink the live view so a wall of them fits */
  dense?: boolean;
  className?: string;
};

const SPECIAL: Record<string, string> = {
  Enter: "Enter",
  Escape: "Escape",
  Tab: "Tab",
  Backspace: "Backspace",
  ArrowUp: "Up",
  ArrowDown: "Down",
  ArrowLeft: "Left",
  ArrowRight: "Right",
};

/**
 * A live pane, streamed straight off the Herdr socket — our own WebSocket,
 * no ttyd and no third-party renderer. The server polls `pane.read` and only
 * ships a frame when the revision moves, so many of these are cheap.
 */
export function PaneView({ member, interactive = false, dense = false, className = "" }: Props) {
  const [text, setText] = useState("");
  // one type size for every pane of this kind, set in settings (⌘,)
  const [settings, setSettings] = useSettings();
  const zoom = dense ? settings.zoomDense : settings.zoom;
  const setZoom = (fn: (z: number) => number) =>
    setSettings(dense ? { zoomDense: fn(settings.zoomDense) } : { zoom: fn(settings.zoom) });
  const [state, setState] = useState<"opening" | "live" | "lost">("opening");
  const [error, setError] = useState("");
  const ws = useRef<WebSocket | null>(null);
  const body = useRef<HTMLPreElement>(null);

  const base = member.base ? member.base.replace(/^http/, "ws") : `${location.protocol === "https:" ? "wss" : "ws"}://${location.host}`;

  useEffect(() => {
    setState("opening");
    setText("");
    const socket = new WebSocket(`${base}/ws/pane/${encodeURIComponent(member.pane)}`);
    ws.current = socket;

    socket.onmessage = (ev: MessageEvent<string>) => {
      const msg = JSON.parse(ev.data) as PaneServerMessage;
      if (msg.type === "frame") {
        setState("live");
        setText(msg.text);
      } else if (msg.type === "error") {
        setError(msg.error);
      }
    };
    socket.onclose = () => setState("lost");
    socket.onerror = () => setState("lost");
    return () => socket.close();
  }, [member.pane, base]);

  useEffect(() => {
    const el = body.current;
    if (el) el.scrollTop = el.scrollHeight;
  }, [text]);

  function onKeyDown(e: React.KeyboardEvent) {
    if (!interactive || ws.current?.readyState !== WebSocket.OPEN) return;
    const mods = [e.ctrlKey && "ctrl", e.altKey && "alt", e.shiftKey && "shift", e.metaKey && "cmd"].filter(Boolean);
    const special = SPECIAL[e.key];

    if (special || (mods.length && e.key.length === 1)) {
      e.preventDefault();
      const key = mods.length ? [...mods, e.key.toLowerCase()].join("+") : special!;
      ws.current.send(JSON.stringify({ type: "keys", keys: [key] }));
      return;
    }
    if (e.key.length === 1 && !e.metaKey) {
      e.preventDefault();
      ws.current.send(JSON.stringify({ type: "text", text: e.key }));
    }
  }

  return (
    <div className={`group relative overflow-hidden bg-[#08090d] ${className}`}>
      <pre
        ref={body}
        tabIndex={interactive ? 0 : -1}
        onKeyDown={onKeyDown}
        style={{ fontSize: `${zoom}px`, lineHeight: 1.4 }}
        className={`h-full w-full overflow-auto m-0 p-3 whitespace-pre text-fg outline-none ${
          interactive ? "focus-visible:ring-1 focus-visible:ring-accent" : ""
        }`}
      >
        {text}
      </pre>

      {state !== "live" && (
        <div className="absolute inset-0 grid place-content-center bg-[#08090db8] text-[11px] text-faint">
          <span className={state === "opening" ? "animate-pulse" : "text-bad"}>
            {state === "opening" ? `opening ${member.handle}…` : `stream lost — ${error || "reconnecting on reload"}`}
          </span>
        </div>
      )}

      <div className="absolute right-1.5 top-1.5 flex items-center gap-1 opacity-0 transition-opacity hover:opacity-100 focus-within:opacity-100 [div:hover>&]:opacity-100 group-hover:opacity-100">
        {interactive && state === "live" && (
          <span className="rounded bg-[#0d1119cc] px-2 py-0.5 text-[10px] text-accent">click to type</span>
        )}
        <button
          onClick={() => setZoom((z) => Math.max(6, z - 1))}
          title="smaller"
          className="grid h-5 w-5 place-items-center rounded bg-[#0d1119cc] text-[11px] text-faint hover:text-fg"
        >
          −
        </button>
        <button
          onClick={() => setZoom((z) => Math.min(24, z + 1))}
          title="bigger"
          className="grid h-5 w-5 place-items-center rounded bg-[#0d1119cc] text-[11px] text-faint hover:text-fg"
        >
          +
        </button>
      </div>
    </div>
  );
}

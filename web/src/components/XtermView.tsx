import { useEffect, useRef, useState } from "react";
import { Terminal } from "@xterm/xterm";
import { FitAddon } from "@xterm/addon-fit";
import "@xterm/xterm/css/xterm.css";
import type { Located, PaneClientMessage, PaneServerMessage } from "../types";

type Props = {
  member: Located;
  interactive?: boolean;
  className?: string;
};

/** herdr's key names, not tmux's: `Enter`, `Escape`, `ctrl+c`, `shift+tab`. */
function keyFor(e: KeyboardEvent): string | null {
  const named: Record<string, string> = {
    Enter: "Enter",
    Escape: "Escape",
    Tab: "Tab",
    Backspace: "Backspace",
    ArrowUp: "Up",
    ArrowDown: "Down",
    ArrowLeft: "Left",
    ArrowRight: "Right",
  };
  const mods = [e.ctrlKey && "ctrl", e.altKey && "alt", e.metaKey && "cmd", e.shiftKey && "shift"].filter(Boolean);
  if (named[e.key]) return mods.length && e.key === "Tab" ? `${mods.join("+")}+tab` : named[e.key];
  if (mods.length && e.key.length === 1) return [...mods, e.key.toLowerCase()].join("+");
  return null;
}

/**
 * The full terminal: xterm.js fed ANSI frames straight off the herdr socket.
 *
 * herdr hands us whole rendered screens rather than an incremental byte stream,
 * so each frame is a repaint — home the cursor, clear, write. `visible` + `ansi`
 * is the read that is both fast and free of side effects on the operator's pane.
 */
export function XtermView({ member, interactive = false, className = "" }: Props) {
  const host = useRef<HTMLDivElement>(null);
  const [state, setState] = useState<"opening" | "live" | "lost">("opening");

  useEffect(() => {
    if (!host.current) return;
    setState("opening");

    const term = new Terminal({
      convertEol: true,
      cursorBlink: interactive,
      disableStdin: !interactive,
      fontFamily: 'ui-monospace, "SF Mono", Menlo, monospace',
      fontSize: 12,
      scrollback: 0, // frames are whole screens; scrollback would stack duplicates
      theme: {
        background: "#08090d",
        foreground: "#d6dae2",
        cursor: "#64b5f6",
        selectionBackground: "#2c5f8a",
      },
    });
    const fit = new FitAddon();
    term.loadAddon(fit);
    term.open(host.current);
    fit.fit();

    const base = member.base
      ? member.base.replace(/^http/, "ws")
      : `${location.protocol === "https:" ? "wss" : "ws"}://${location.host}`;
    const ws = new WebSocket(`${base}/ws/pane/${encodeURIComponent(member.pane)}?format=ansi`);

    ws.onmessage = (ev: MessageEvent<string>) => {
      const msg = JSON.parse(ev.data) as PaneServerMessage;
      if (msg.type !== "frame") return;
      setState("live");
      term.write(`\x1b[H\x1b[2J${msg.text}`);
    };
    ws.onclose = () => setState("lost");
    ws.onerror = () => setState("lost");

    const send = (payload: PaneClientMessage) => ws.readyState === WebSocket.OPEN && ws.send(JSON.stringify(payload));

    // printable input goes as raw text; everything else as a named herdr key
    const data = interactive ? term.onData((d) => send({ type: "text", text: d })) : null;
    const keys = interactive
      ? term.attachCustomKeyEventHandler((e) => {
          if (e.type !== "keydown") return true;
          const key = keyFor(e);
          if (!key) return true;
          send({ type: "keys", keys: [key] });
          return false;
        })
      : null;

    const onResize = () => fit.fit();
    addEventListener("resize", onResize);
    const ro = new ResizeObserver(() => fit.fit());
    ro.observe(host.current);

    return () => {
      removeEventListener("resize", onResize);
      ro.disconnect();
      data?.dispose();
      void keys;
      ws.close();
      term.dispose();
    };
  }, [member.pane, member.base, interactive]);

  return (
    <div className={`relative overflow-hidden bg-[#08090d] ${className}`}>
      <div ref={host} className="h-full w-full [&_.xterm]:h-full [&_.xterm-viewport]:overflow-hidden" />
      {state !== "live" && (
        <div className="absolute inset-0 grid place-content-center bg-[#08090db8] text-[11px] text-faint">
          <span className={state === "opening" ? "animate-pulse" : "text-bad"}>
            {state === "opening" ? `opening ${member.handle}…` : "stream lost — reload to reconnect"}
          </span>
        </div>
      )}
    </div>
  );
}

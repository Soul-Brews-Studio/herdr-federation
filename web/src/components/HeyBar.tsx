import { useEffect, useState } from "react";
import { api } from "../api";
import type { CallRecord, Status } from "../types";
import { Send } from "./Icons";

/** `maw hey`, from the browser: the channel, or one agent's pane. */
export function HeyBar({ status }: { status: Status | null }) {
  const [to, setTo] = useState("*");
  // the last thing this node actually said to herdr, always on screen
  const [last, setLast] = useState<CallRecord | null>(null);

  useEffect(() => {
    let alive = true;
    const tick = async () => {
      try {
        const out = await api.calls(1);
        if (alive) setLast(out.calls[0] ?? null);
      } catch {
        /* relay restarting */
      }
    };
    void tick();
    const id = setInterval(tick, 1000);
    return () => {
      alive = false;
      clearInterval(id);
    };
  }, []);
  const [text, setText] = useState("");
  const [busy, setBusy] = useState(false);
  const [msg, setMsg] = useState<{ text: string; bad?: boolean } | null>(null);

  async function send(e: React.FormEvent) {
    e.preventDefault();
    if (!text.trim()) return;
    setBusy(true);
    try {
      const out = await api.hey(to, text);
      setText("");
      setMsg({ text: out.delivered === "pane" ? `typed into ${out.to}'s pane` : "sent · relaying to peers" });
    } catch (err) {
      setMsg({ text: `not sent — ${(err as Error).message}`, bad: true });
    } finally {
      setBusy(false);
      setTimeout(() => setMsg(null), 4000);
    }
  }

  const panes = (status?.members ?? []).filter((m) => m.pane);

  return (
    <>
      <form onSubmit={send} autoComplete="off" className="grid grid-cols-[auto_auto_1fr_auto] items-center gap-2.5 border-t border-edge bg-panel px-3 py-2.5">
        <span className="text-accent">hey</span>
        <select
          value={to}
          onChange={(e) => setTo(e.target.value)}
          aria-label="delivery target"
          className="min-w-0 rounded-md border border-edge-bright bg-[#0b0e13] px-2.5 py-1.5"
        >
          <option value="*">everyone · the federation</option>
          {panes.map((m) => (
            <option key={m.pane} value={m.handle}>
              {m.handle} · pane
            </option>
          ))}
        </select>
        <input
          type="text"
          value={text}
          onChange={(e) => setText(e.target.value)}
          placeholder="message the federation, or type straight into an agent's pane"
          aria-label="message"
          className="min-w-0 rounded-md border border-edge-bright bg-[#0b0e13] px-2.5 py-1.5 placeholder:text-[#545c6a]"
        />
        <button
          type="submit"
          disabled={busy}
          className="inline-flex items-center gap-2 rounded-md bg-accent px-3.5 py-1.5 font-semibold text-[#07131d] hover:bg-[#7cc3ff] disabled:cursor-not-allowed disabled:bg-[#22364a] disabled:text-faint"
        >
          <Send className="w-[13px] h-[13px]" />
          send
        </button>
      </form>
      <div className="flex items-center gap-2 border-t border-edge bg-rail px-3.5 py-1.5 text-[11px] text-faint">
        <span>{status?.node ?? "…"}</span>
        <span className="text-[#333a46]">·</span>
        <span>{status?.members?.length ?? 0} agents here</span>
        <span className="text-[#333a46]">·</span>
        <span>
          {status?.peers?.length ? `${status.peers.filter((p) => p.ok).length}/${status.peers.length} peers` : "no peers"}
        </span>
        {last && !msg && (
          <button
            title="the last call this node made to herdr — click to copy"
            onClick={() => last.cli && navigator.clipboard.writeText(last.cli)}
            className="ml-auto flex min-w-0 items-baseline gap-2 text-faint hover:text-dim"
          >
            <span className={last.ok ? "text-[#4b5261]" : "text-bad"}>{last.ms}ms</span>
            <span className="truncate font-mono">{last.cli ?? last.method}</span>
          </button>
        )}
        {msg && <span className={`ml-auto ${msg.bad ? "text-bad" : "text-dim"}`}>{msg.text}</span>}
      </div>
    </>
  );
}

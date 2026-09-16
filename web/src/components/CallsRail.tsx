import { useEffect, useState } from "react";
import { api } from "../api";
import type { CallRecord, Status } from "../types";

/**
 * Every socket transaction this node makes, with the command line you could
 * have typed instead. Nothing the console does should be a black box.
 */
export function CallsRail({ status }: { status: Status | null }) {
  const [tab, setTab] = useState<"federation" | "calls">("federation");
  const [calls, setCalls] = useState<CallRecord[]>([]);
  const [copied, setCopied] = useState<string | null>(null);

  useEffect(() => {
    if (tab !== "calls") return;
    let alive = true;
    const tick = async () => {
      try {
        const out = await api.calls(60);
        if (alive) setCalls(out.calls);
      } catch {
        /* relay restarting */
      }
    };
    void tick();
    const id = setInterval(tick, 1200);
    return () => {
      alive = false;
      clearInterval(id);
    };
  }, [tab]);

  return (
    <div className="max-h-[168px] overflow-y-auto border-t border-edge bg-rail">
      <div className="sticky top-0 flex gap-3.5 bg-rail px-4 pt-2.5 pb-1 text-[11px] tracking-[.08em]">
        {(["federation", "calls"] as const).map((t) => (
          <button key={t} onClick={() => setTab(t)} className={tab === t ? "text-accent" : "text-faint hover:text-dim"}>
            {t === "calls" ? "herdr calls" : "federation"}
          </button>
        ))}
        {tab === "calls" && <span className="ml-auto text-[#4b5261]">click to copy</span>}
      </div>

      {tab === "federation" ? (
        status?.messages?.length ? (
          status.messages.map((m) => (
            <div key={m.id} className="grid grid-cols-[58px_70px_1fr] gap-2.5 px-4 py-0.5 text-[11px]">
              <time className="text-[#555c6a]">{m.at.slice(11, 19)}</time>
              <span className={m.node === status.node ? "text-accent" : "text-live"}>{m.node}</span>
              <span className="truncate text-dim">{m.text}</span>
            </div>
          ))
        ) : (
          <div className="px-4 pb-2.5 text-[11px] text-[#4b5261]">nothing said yet</div>
        )
      ) : calls.length ? (
        calls.map((c, i) => (
          <button
            key={`${c.at}-${i}`}
            onClick={() => {
              const line = c.cli ?? JSON.stringify({ method: c.method, params: c.params });
              void navigator.clipboard.writeText(line);
              setCopied(`${c.at}-${i}`);
              setTimeout(() => setCopied(null), 1500);
            }}
            className="grid w-full grid-cols-[58px_46px_1fr] items-baseline gap-2.5 px-4 py-0.5 text-left text-[11px] hover:bg-[#151922]"
          >
            <time className="text-[#555c6a]">{c.at.slice(11, 19)}</time>
            <span className={c.ok ? "text-faint" : "text-bad"}>{c.ms}ms</span>
            <span className="truncate">
              {copied === `${c.at}-${i}` ? (
                <span className="text-ok">copied</span>
              ) : c.cli ? (
                <span className="text-dim">{c.cli}</span>
              ) : (
                <span className="text-faint">
                  {c.method} <span className="text-[#4b5261]">{JSON.stringify(c.params).slice(0, 90)}</span>
                </span>
              )}
              {c.error && <span className="text-bad"> — {c.error}</span>}
            </span>
          </button>
        ))
      ) : (
        <div className="px-4 pb-2.5 text-[11px] text-[#4b5261]">no calls yet</div>
      )}
    </div>
  );
}

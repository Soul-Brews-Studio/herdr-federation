import { useState } from "react";
import type { AuditAction, AuditEntry } from "../../types";

/** Every membership decision this node made, newest first, with its steps. */

const TONE: Record<AuditAction, string> = {
  "invite.create": "text-accent",
  "invite.revoke": "text-faint",
  "member.join": "text-ok",
  "member.kick": "text-warn",
  "member.ban": "text-bad",
  "member.unban": "text-accent",
  "redeem.reject": "text-bad",
  "kick.adopt": "text-warn",
};

const FILTERS: (AuditAction | "all")[] = ["all", "member.join", "member.kick", "member.ban", "invite.create", "redeem.reject"];

export function AuditLog({ audit }: { audit: AuditEntry[] }) {
  const [filter, setFilter] = useState<AuditAction | "all">("all");
  const [open, setOpen] = useState<string | null>(null);
  const rows = filter === "all" ? audit : audit.filter((e) => e.action === filter);

  return (
    <section className="rounded-lg border border-edge bg-panel">
      <header className="flex flex-wrap items-baseline gap-1.5 border-b border-edge px-3 py-2">
        <b className="font-semibold">audit log</b>
        <span className="text-[11px] text-faint">last 500 · this node only</span>
        <div className="ml-auto flex gap-1">
          {FILTERS.map((f) => (
            <button
              key={f}
              onClick={() => setFilter(f)}
              className={`rounded px-2 py-0.5 text-[11px] ${filter === f ? "bg-[#1d2532] text-accent" : "text-faint hover:text-dim"}`}
            >
              {f}
            </button>
          ))}
        </div>
      </header>

      {rows.length ? (
        rows.map((e) => (
          <div key={e.id} className="border-b border-edge last:border-b-0">
            <button onClick={() => setOpen(open === e.id ? null : e.id)} className="grid w-full grid-cols-[130px_120px_1fr_auto] items-baseline gap-3 px-3 py-1.5 text-left hover:bg-[#161b24]">
              <span className="text-[11px] text-faint">{new Date(e.at).toLocaleString()}</span>
              <span className={`text-[11px] ${TONE[e.action]}`}>{e.action}</span>
              <span className="truncate">
                {e.node}
                {e.summary ? <span className="text-[11px] text-faint"> · {e.summary}</span> : null}
                {e.reason && e.reason !== e.summary ? <span className="text-[11px] text-warn"> · {e.reason}</span> : null}
              </span>
              <span className="text-[11px] text-faint">
                {e.steps.some((s) => !s.ok) && <span className="text-bad">✕ </span>}
                {open === e.id ? "−" : `${e.steps.length} steps`}
              </span>
            </button>
            {open === e.id && (
              <ol className="border-t border-edge bg-[#0b0e13] px-3 py-2">
                {e.steps.map((s) => (
                  <li key={s.n} className="grid grid-cols-[16px_1fr] gap-2 py-0.5">
                    <span className={s.ok ? "text-ok" : "text-bad"}>{s.ok ? "✓" : "✕"}</span>
                    <div className="min-w-0">
                      <div className="text-[11px]">{s.label}</div>
                      {s.detail && <div className="break-words text-[11px] text-faint">{s.detail}</div>}
                      {s.wire && <div className="break-all text-[11px] text-accent-dim">{s.wire}</div>}
                    </div>
                  </li>
                ))}
              </ol>
            )}
          </div>
        ))
      ) : (
        <div className="px-3 py-3 text-[11px] text-faint">nothing recorded under this filter</div>
      )}
    </section>
  );
}

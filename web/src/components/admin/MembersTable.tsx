import { useState } from "react";
import { api } from "../../api";
import type { AdminState, AuditEntry, BanRecord, MemberRecord } from "../../types";

/**
 * Two lists, never merged.
 *
 * The first is who federates with THIS node — the only rows this page can act
 * on. The second is what the rest of the mesh reports about itself, which is
 * information and nothing more. Blurring them would make the page claim an
 * authority the architecture does not give it.
 */

const ago = (iso?: string) => {
  if (!iso) return "never";
  const s = Math.round((Date.now() - Date.parse(iso)) / 1000);
  if (s < 60) return `${s}s ago`;
  if (s < 3600) return `${Math.round(s / 60)}m ago`;
  if (s < 86400) return `${Math.round(s / 3600)}h ago`;
  return new Date(iso).toLocaleDateString();
};

function Confirm({ verb, node, onDone }: { verb: "kick" | "ban"; node: string; onDone: () => void }) {
  const [reason, setReason] = useState("");
  const [busy, setBusy] = useState(false);
  const [err, setErr] = useState<string | null>(null);

  const go = async () => {
    setBusy(true);
    try {
      await (verb === "ban" ? api.ban(node, reason || undefined) : api.kick(node, reason || undefined));
      onDone();
    } catch (e) {
      setErr((e as Error).message);
      setBusy(false);
    }
  };

  return (
    <div className="col-span-full mt-1 rounded-md border border-edge-bright bg-[#0b0e13] p-2.5">
      <div className="pb-1.5 text-[11px] text-dim">
        {verb === "kick" ? (
          <>
            <b className="text-fg">kick {node}</b> — their token dies here and this node stops syncing with them. They
            can come back through any invite that is still valid.
          </>
        ) : (
          <>
            <b className="text-warn">ban {node}</b> — same as a kick, and their key is pinned so no invite lets them
            back in.
          </>
        )}
      </div>
      <div className="grid grid-cols-[1fr_auto_auto] gap-2">
        <input
          autoFocus
          value={reason}
          onChange={(e) => setReason(e.target.value)}
          placeholder="reason (optional — it goes in the audit log and is published)"
          className="min-w-0 rounded border border-edge-bright bg-bg px-2 py-1 placeholder:text-[#545c6a]"
        />
        <button onClick={onDone} className="rounded px-2.5 py-1 text-[11px] text-faint hover:text-fg">
          cancel
        </button>
        <button
          onClick={go}
          disabled={busy}
          className={`rounded px-3 py-1 text-[11px] font-semibold ${
            verb === "ban" ? "bg-bad text-[#2a0d0b]" : "bg-warn text-[#2a1e07]"
          } disabled:opacity-50`}
        >
          {busy ? "…" : verb}
        </button>
      </div>
      {err && <div className="pt-1.5 text-[11px] text-bad">{err}</div>}
    </div>
  );
}

function Row({ m, onChanged }: { m: MemberRecord; onChanged: () => void }) {
  const [confirm, setConfirm] = useState<"kick" | "ban" | null>(null);
  return (
    <div className="grid grid-cols-[1fr_auto] items-baseline gap-x-3 border-b border-edge px-3 py-2 last:border-b-0">
      <div className="min-w-0">
        <div className="flex flex-wrap items-baseline gap-2">
          <b className="font-semibold">{m.node}</b>
          {m.legacy ? (
            <span className="rounded bg-[#3a2f14] px-1.5 py-px text-[10px] text-warn">unverified · pre-token peer</span>
          ) : (
            <span className="text-[11px] text-faint">{m.fingerprint}</span>
          )}
        </div>
        <div className="truncate text-[11px] text-faint">
          {m.url ?? "address unknown"} · joined {ago(m.joinedAt)}
          {m.viaInvite ? ` via invite ${m.viaInvite}` : ""} · seen {ago(m.lastSeen)}
        </div>
      </div>
      <div className="flex gap-1">
        <button onClick={() => setConfirm(confirm === "kick" ? null : "kick")} className="rounded px-2 py-0.5 text-[11px] text-faint hover:bg-[#2a1e07] hover:text-warn">
          kick
        </button>
        <button onClick={() => setConfirm(confirm === "ban" ? null : "ban")} className="rounded px-2 py-0.5 text-[11px] text-faint hover:bg-[#3a1b1b] hover:text-bad">
          ban
        </button>
      </div>
      {confirm && <Confirm verb={confirm} node={m.node} onDone={() => { setConfirm(null); onChanged(); }} />}
    </div>
  );
}

export function MembersTable({ state, onChanged }: { state: AdminState; onChanged: () => void }) {
  const mesh = Object.entries(state.meshMembers).filter(([, list]) => (list ?? []).length);

  return (
    <div className="grid gap-4">
      <section className="rounded-lg border border-edge bg-panel">
        <header className="flex items-baseline gap-2 border-b border-edge px-3 py-2">
          <b className="font-semibold">federated with {state.node}</b>
          <span className="text-[11px] text-faint">this node's own door · {state.members.length}</span>
        </header>
        {state.members.length ? (
          state.members.map((m) => <Row key={m.node} m={m} onChanged={onChanged} />)
        ) : (
          <div className="px-3 py-3 text-[11px] text-faint">nobody yet — create an invite and send the link</div>
        )}
      </section>

      {state.adoptable.length > 0 && (
        <section className="rounded-lg border border-warn/40 bg-panel">
          <header className="flex items-baseline gap-2 border-b border-edge px-3 py-2">
            <b className="font-semibold text-warn">kicks published by peers</b>
            <span className="text-[11px] text-faint">they kicked someone you still federate with — your call</span>
          </header>
          {state.adoptable.map((e) => (
            <AdoptRow key={e.id} entry={e} onChanged={onChanged} />
          ))}
        </section>
      )}

      <section className="rounded-lg border border-edge bg-panel">
        <header className="flex items-baseline gap-2 border-b border-edge px-3 py-2">
          <b className="font-semibold">elsewhere in the mesh</b>
          <span className="text-[11px] text-faint">what peers report about themselves · read-only here</span>
        </header>
        {mesh.length ? (
          mesh.map(([peer, list]) => (
            <div key={peer} className="border-b border-edge px-3 py-2 last:border-b-0">
              <div className="text-[11px] tracking-[.08em] text-faint">{peer} federates with</div>
              <div className="flex flex-wrap gap-1.5 pt-1">
                {list.map((m) => (
                  <span key={m.node} className="rounded bg-[#1a1e27] px-2 py-0.5 text-[11px] text-dim" title={m.fingerprint}>
                    {m.node}
                  </span>
                ))}
              </div>
            </div>
          ))
        ) : (
          <div className="px-3 py-3 text-[11px] text-faint">no peer has reported its membership yet</div>
        )}
      </section>
    </div>
  );
}

function AdoptRow({ entry, onChanged }: { entry: AuditEntry & { from: string }; onChanged: () => void }) {
  const [busy, setBusy] = useState(false);
  return (
    <div className="flex flex-wrap items-baseline gap-2 border-b border-edge px-3 py-2 last:border-b-0">
      <span>
        <b>{entry.from}</b> kicked <b>{entry.node}</b>
      </span>
      <span className="text-[11px] text-faint">{entry.reason ?? "no reason given"}</span>
      <button
        onClick={async () => {
          setBusy(true);
          try {
            await api.adoptKick(entry.node, entry.from, entry.reason);
          } finally {
            setBusy(false);
            onChanged();
          }
        }}
        disabled={busy}
        className="ml-auto rounded bg-[#2a1e07] px-2.5 py-0.5 text-[11px] text-warn hover:bg-[#3a2a0a] disabled:opacity-50"
      >
        {busy ? "…" : `kick ${entry.node} here too`}
      </button>
    </div>
  );
}

export function BansTable({ bans, onChanged }: { bans: BanRecord[]; onChanged: () => void }) {
  return (
    <section className="rounded-lg border border-edge bg-panel">
      <header className="flex items-baseline gap-2 border-b border-edge px-3 py-2">
        <b className="font-semibold">banned keys</b>
        <span className="text-[11px] text-faint">no invite lets these back in · {bans.length}</span>
      </header>
      {bans.length ? (
        bans.map((b) => (
          <div key={b.node + b.at} className="grid grid-cols-[1fr_auto] items-baseline gap-3 border-b border-edge px-3 py-2 last:border-b-0">
            <div className="min-w-0">
              <b>{b.node}</b>
              <div className="truncate text-[11px] text-faint">
                {b.pubkey ? `key ${b.pubkey.slice(0, 16)}` : "no key on record — the node name is pinned"} ·{" "}
                {new Date(b.at).toLocaleString()}
                {b.reason ? ` · ${b.reason}` : ""}
              </div>
            </div>
            <button
              onClick={async () => {
                await api.unban(b.node);
                onChanged();
              }}
              className="rounded px-2 py-0.5 text-[11px] text-faint hover:text-accent"
            >
              unban
            </button>
          </div>
        ))
      ) : (
        <div className="px-3 py-3 text-[11px] text-faint">nobody is banned</div>
      )}
    </section>
  );
}

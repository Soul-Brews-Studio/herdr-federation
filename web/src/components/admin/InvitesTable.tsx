import { useState } from "react";
import { api } from "../../api";
import type { AdminState, InviteLink } from "../../types";
import { Pick, Row, Stepper } from "../Bits";

/**
 * Invites, Discord's way: the secret is in the link, the link is spent when
 * someone redeems it, and revoking a link never touches whoever already used it.
 */

const when = (iso: string | null) => {
  if (!iso) return "never expires";
  const left = Date.parse(iso) - Date.now();
  if (left <= 0) return "expired";
  const h = Math.floor(left / 3600_000);
  return h >= 1 ? `${h}h left` : `${Math.max(1, Math.round(left / 60_000))}m left`;
};

const TONE: Record<InviteLink["status"], string> = {
  active: "text-ok",
  expired: "text-faint",
  revoked: "text-faint",
  exhausted: "text-faint",
};

function Create({ onCreated }: { onCreated: () => void }) {
  const [hours, setHours] = useState(24);
  const [never, setNever] = useState(false);
  const [once, setOnce] = useState(false);
  const [note, setNote] = useState("");
  const [busy, setBusy] = useState(false);
  const [err, setErr] = useState<string | null>(null);

  const create = async () => {
    setBusy(true);
    setErr(null);
    try {
      await api.createInvite({ hours: never ? null : hours, uses: once ? 1 : null, note: note || undefined });
      setNote("");
      onCreated();
    } catch (e) {
      setErr((e as Error).message);
    } finally {
      setBusy(false);
    }
  };

  return (
    <section className="rounded-lg border border-edge bg-panel">
      <header className="border-b border-edge px-4 py-2">
        <b className="font-semibold">new invite</b>
      </header>

      <Row label="expires after" hint="a forgotten link closes itself">
        {never ? <span className="px-2 text-[11px] text-dim">never</span> : <Stepper value={hours} set={setHours} min={1} max={720} unit="h" />}
        <Pick value={never} onPick={setNever} options={[{ v: false, label: "timed" }, { v: true, label: "never" }]} />
      </Row>

      <Row label="uses" hint="unlimited is right when you are adding several machines from one link">
        <Pick value={once} onPick={setOnce} options={[{ v: false, label: "unlimited" }, { v: true, label: "once" }]} />
      </Row>

      <Row label="note" hint="shown to whoever opens the link">
        <input
          value={note}
          onChange={(e) => setNote(e.target.value)}
          placeholder="for the lab machine"
          className="w-56 rounded border border-edge-bright bg-bg px-2 py-1 placeholder:text-[#545c6a]"
        />
      </Row>

      <div className="flex items-center gap-3 border-t border-edge bg-[#0f1218] px-4 py-2.5">
        {err && <span className="text-[11px] text-bad">{err}</span>}
        <button
          onClick={create}
          disabled={busy}
          className="ml-auto rounded-md bg-accent px-4 py-1 font-semibold text-[#07131d] hover:bg-[#7cc3ff] disabled:bg-[#22364a] disabled:text-faint"
        >
          {busy ? "…" : "create invite link"}
        </button>
      </div>
    </section>
  );
}

function InviteRow({ inv, onChanged }: { inv: InviteLink; onChanged: () => void }) {
  const [copied, setCopied] = useState(false);
  return (
    <div className="border-b border-edge px-3 py-2 last:border-b-0">
      <div className="flex flex-wrap items-baseline gap-2">
        <span className={`text-[11px] ${TONE[inv.status]}`}>{inv.status}</span>
        <span className="text-[11px] text-faint">
          {when(inv.expiresAt)} · used {inv.uses}
          {inv.maxUses === null ? "" : `/${inv.maxUses}`}
          {inv.usedBy.length ? ` by ${inv.usedBy.map((u) => u.node).join(", ")}` : ""}
        </span>
        {inv.note && <span className="text-[11px] text-dim">“{inv.note}”</span>}
        {inv.status === "active" && (
          <button
            onClick={async () => {
              await api.revokeInvite(inv.id);
              onChanged();
            }}
            className="ml-auto text-[11px] text-faint hover:text-bad"
          >
            revoke
          </button>
        )}
      </div>
      <button
        disabled={!inv.url}
        onClick={() => {
          if (!inv.url) return;
          void navigator.clipboard.writeText(inv.url);
          setCopied(true);
          setTimeout(() => setCopied(false), 1500);
        }}
        className="mt-1 w-full truncate rounded border border-edge-bright bg-[#0b0e13] px-2 py-1 text-left text-[11px] hover:border-accent-dim disabled:cursor-not-allowed disabled:text-faint"
      >
        {copied ? "copied" : (inv.url ?? "this node has no address to put in a link — set FED_ADVERTISE")}
      </button>
    </div>
  );
}

export function InvitesTable({ state, onChanged }: { state: AdminState; onChanged: () => void }) {
  return (
    <div className="grid gap-4">
      <Create onCreated={onChanged} />
      <section className="rounded-lg border border-edge bg-panel">
        <header className="flex items-baseline gap-2 border-b border-edge px-3 py-2">
          <b className="font-semibold">invites</b>
          <span className="text-[11px] text-faint">revoking one never removes a member who already joined</span>
        </header>
        {state.invites.length ? (
          state.invites.map((i) => <InviteRow key={i.id} inv={i} onChanged={onChanged} />)
        ) : (
          <div className="px-3 py-3 text-[11px] text-faint">no invites yet</div>
        )}
      </section>
    </div>
  );
}

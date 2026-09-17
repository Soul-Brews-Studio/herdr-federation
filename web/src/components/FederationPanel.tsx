import { useState } from "react";
import { api } from "../api";
import type { Status } from "../types";

/**
 * The federation, as a thing you join — with an invite link, the way you join a
 * Discord server. Paste the whole link; the secret in it is what gets you in.
 *
 * A one-way link is normal here (userspace-mode NetBird blackholes inbound), so
 * a node we can only *hear* from is shown as heard, not as broken.
 */

/** `http://host:6750/join/<secret>` → the parts our node needs to redeem it. */
function parseInvite(raw: string): { from: string; token: string } | null {
  try {
    const u = new URL(raw.trim());
    const m = u.pathname.match(/^\/join\/(.+)$/);
    if (!m) return null;
    return { from: u.origin, token: decodeURIComponent(m[1]) };
  } catch {
    return null;
  }
}

export function FederationPanel({ status, onClose }: { status: Status | null; onClose: () => void }) {
  const [link, setLink] = useState("");
  const [busy, setBusy] = useState(false);
  const [msg, setMsg] = useState<{ text: string; bad?: boolean } | null>(null);

  async function join(e: React.FormEvent) {
    e.preventDefault();
    const parsed = parseInvite(link);
    if (!parsed) {
      setMsg({ text: "that is not an invite link — it looks like http://host:6750/join/<secret>", bad: true });
      return;
    }
    setBusy(true);
    try {
      const out = await api.redeem(parsed.from, parsed.token);
      setLink("");
      setMsg({ text: `joined ${out.joined.node}` });
    } catch (err) {
      setMsg({ text: (err as Error).message, bad: true });
    } finally {
      setBusy(false);
    }
  }

  const heardOnly = (status?.known ?? []).filter((k) => !status?.peers?.some((p) => p.name === k.node));

  return (
    <div className="fixed inset-0 z-40 grid place-items-start justify-center bg-[#05070ad0] pt-[10vh]" onClick={onClose}>
      <div
        onClick={(e) => e.stopPropagation()}
        className="w-[min(92vw,620px)] overflow-hidden rounded-lg border border-edge-bright bg-panel shadow-[0_24px_60px_-24px_rgba(0,0,0,.95)]"
      >
        <div className="flex items-baseline gap-2.5 border-b border-edge px-4 py-3">
          <b className="font-semibold">the federation</b>
          <span className="text-[11px] text-faint">
            {status?.node}
            {status?.identity ? ` · key ${status.identity.fingerprint}` : ""}
          </span>
          <button onClick={onClose} className="ml-auto text-faint hover:text-fg">
            esc
          </button>
        </div>

        <form onSubmit={join} className="grid grid-cols-[1fr_auto] gap-2.5 px-4 py-3">
          <input
            value={link}
            onChange={(e) => setLink(e.target.value)}
            placeholder="paste an invite link — http://host:6750/join/<secret>"
            aria-label="invite link"
            className="min-w-0 rounded-md border border-edge-bright bg-[#0b0e13] px-2.5 py-1.5 placeholder:text-[#545c6a]"
          />
          <button
            type="submit"
            disabled={busy}
            className="rounded-md bg-accent px-4 py-1.5 font-semibold text-[#07131d] hover:bg-[#7cc3ff] disabled:bg-[#22364a] disabled:text-faint"
          >
            {busy ? "joining…" : "join"}
          </button>
        </form>
        {msg && <div className={`px-4 pb-2 text-[11px] ${msg.bad ? "text-bad" : "text-ok"}`}>{msg.text}</div>}

        <div className="border-t border-edge px-4 py-3">
          <div className="pb-1.5 text-[11px] tracking-[.08em] text-faint">joined</div>
          {status?.peers?.length ? (
            status.peers.map((p) => (
              <div key={p.name} className="flex items-center gap-2.5 py-1">
                <span className={`h-[7px] w-[7px] rounded-full ${p.ok ? "bg-ok" : "bg-bad"}`} />
                <span>{p.name}</span>
                <span className="truncate text-[11px] text-faint">
                  {p.url}
                  {p.via ? ` · via ${p.via}` : ""}
                </span>
                <span className="ml-auto text-[11px] text-faint">{(status.peerMembers?.[p.name] ?? []).length} panes</span>
              </div>
            ))
          ) : (
            <div className="text-[11px] text-[#4b5261]">no hubs joined yet</div>
          )}

          {heardOnly.length > 0 && (
            <>
              <div className="pb-1.5 pt-3 text-[11px] tracking-[.08em] text-faint">heard from, not joined</div>
              {heardOnly.map((k) => (
                <div key={k.node} className="flex items-center gap-2.5 py-1">
                  <span className="h-[7px] w-[7px] rounded-full bg-live" />
                  <span>{k.node}</span>
                  <span className="truncate text-[11px] text-faint">{k.url ?? "address unknown — it reached us"}</span>
                </div>
              ))}
            </>
          )}
        </div>

        <div className="flex items-baseline gap-3 border-t border-edge bg-[#0f1218] px-4 py-3 text-[11px]">
          <span className="text-faint">invites, kicks, bans and the audit log live on the admin page</span>
          <a href="/admin" className="ml-auto font-semibold text-accent hover:underline">
            open admin →
          </a>
        </div>
      </div>
    </div>
  );
}

import { useState } from "react";
import { api } from "../api";
import type { Status } from "../types";

/**
 * The federation, as a thing you join. Paste a node's address the way you paste
 * a Discord invite; gossip spreads the rest of the mesh from there.
 *
 * A one-way link is normal (userspace-mode NetBird blackholes inbound), so a
 * node we can only *hear* from is shown as heard, not as broken.
 */
export function FederationPanel({ status, onClose }: { status: Status | null; onClose: () => void }) {
  const [url, setUrl] = useState("");
  const [busy, setBusy] = useState(false);
  const [msg, setMsg] = useState<{ text: string; bad?: boolean } | null>(null);
  const [copied, setCopied] = useState(false);

  async function join(e: React.FormEvent) {
    e.preventDefault();
    if (!url.trim()) return;
    setBusy(true);
    try {
      const out = await api.join(url);
      setUrl("");
      setMsg({ text: `joined ${out.joined.node}` });
    } catch (err) {
      setMsg({ text: (err as Error).message, bad: true });
    } finally {
      setBusy(false);
    }
  }

  const leave = (name: string) => api.leave(name);

  const invite = status?.invite;
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
            {status?.session ? ` · session ${status.session}` : ""}
          </span>
          <button onClick={onClose} className="ml-auto text-faint hover:text-fg">
            esc
          </button>
        </div>

        <form onSubmit={join} className="grid grid-cols-[1fr_auto] gap-2.5 px-4 py-3">
          <input
            value={url}
            onChange={(e) => setUrl(e.target.value)}
            placeholder="http://node.address:6750 — paste a hub to join"
            aria-label="hub address"
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
                <button onClick={() => leave(p.name)} className="text-[11px] text-faint hover:text-bad">
                  leave
                </button>
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
                  {k.url && (
                    <button
                      onClick={() => setUrl(k.url!)}
                      className="ml-auto text-[11px] text-accent hover:underline"
                    >
                      join back
                    </button>
                  )}
                </div>
              ))}
            </>
          )}
        </div>

        <div className="border-t border-edge bg-[#0f1218] px-4 py-3">
          <div className="pb-1.5 text-[11px] tracking-[.08em] text-faint">invite others to this node</div>
          {invite?.url ? (
            <button
              onClick={() => {
                void navigator.clipboard.writeText(invite.url!);
                setCopied(true);
                setTimeout(() => setCopied(false), 2000);
              }}
              className="w-full truncate rounded-md border border-edge-bright bg-[#0b0e13] px-2.5 py-1.5 text-left hover:border-accent-dim"
            >
              {copied ? "copied" : invite.url}
            </button>
          ) : (
            <div className="text-[11px] text-warn">{invite?.hint ?? "not joinable from other machines"}</div>
          )}
        </div>
      </div>
    </div>
  );
}

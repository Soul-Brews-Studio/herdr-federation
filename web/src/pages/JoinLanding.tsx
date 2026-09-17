import { useEffect, useState } from "react";
import { api } from "../api";
import type { InvitePreview, Status } from "../types";

/**
 * Two screens, one route — the same split Discord has.
 *
 * `/join/<token>` is served BY the node that issued the invite. Opening it in a
 * browser proves nothing and joins nothing: the thing that has to join is the
 * reader's *node*, not their browser. So this screen hands off to their own
 * console, the way an invite page hands off to the app.
 *
 * `/join?from=…&t=…` is that handoff landing on their own node, where the
 * console can actually act. It never joins automatically — a link anyone can
 * send you must not be able to federate your machine on its own.
 */

const Shell = ({ children }: { children: React.ReactNode }) => (
  <div className="grid h-dvh place-items-center bg-bg p-4">
    <div className="w-[min(94vw,520px)] overflow-hidden rounded-lg border border-edge-bright bg-panel shadow-[0_24px_60px_-24px_rgba(0,0,0,.95)]">
      {children}
    </div>
  </div>
);

const Head = ({ title, sub }: { title: string; sub?: string }) => (
  <div className="border-b border-edge px-4 py-3">
    <b className="font-semibold">{title}</b>
    {sub && <div className="text-[11px] text-faint">{sub}</div>}
  </div>
);

/** Screen 1 — the issuer's invite page. */
function Invitation({ token }: { token: string }) {
  const [preview, setPreview] = useState<InvitePreview | null>(null);
  const [err, setErr] = useState<string | null>(null);
  const [mine, setMine] = useState("http://127.0.0.1:6750");

  useEffect(() => {
    api
      .previewInvite("", token)
      .then(setPreview)
      .catch((e) => setErr((e as Error).message));
  }, [token]);

  if (err) return <Shell><Head title="this invite does not work" sub={err} /></Shell>;
  if (!preview) return <Shell><Head title="…" /></Shell>;

  const dead = preview.status !== "active";
  const handoff = `${mine.replace(/\/+$/, "")}/join?from=${encodeURIComponent(preview.url ?? location.origin)}&t=${encodeURIComponent(token)}`;

  return (
    <Shell>
      <Head title={`${preview.node} invited you`} sub={`key ${preview.fingerprint} · ${preview.members} members`} />
      <div className="px-4 py-3">
        {preview.note && <div className="pb-2 text-dim">“{preview.note}”</div>}
        <div className="text-[11px] text-faint">
          {dead ? (
            <span className="text-bad">this invite is {preview.status}</span>
          ) : (
            <>expires {preview.expiresAt ? new Date(preview.expiresAt).toLocaleString() : "never"} · created by {preview.createdBy}</>
          )}
        </div>
      </div>

      {!dead && (
        <div className="border-t border-edge bg-[#0f1218] px-4 py-3">
          <div className="pb-1.5 text-[11px] tracking-[.08em] text-faint">your own console</div>
          <input
            value={mine}
            onChange={(e) => setMine(e.target.value)}
            aria-label="your console address"
            className="w-full rounded border border-edge-bright bg-bg px-2 py-1.5"
          />
          <a
            href={handoff}
            className="mt-2 block rounded-md bg-accent px-4 py-1.5 text-center font-semibold text-[#07131d] hover:bg-[#7cc3ff]"
          >
            join as my node
          </a>
          <div className="pt-2 text-[11px] text-faint">
            Your browser cannot join anything — your node does. This hands the invite to the console running on your
            own machine, which will ask you to confirm.
          </div>
        </div>
      )}
    </Shell>
  );
}

/** Screen 2 — the handoff, landing on the reader's own node. */
function Confirm({ from, token, status }: { from: string; token: string; status: Status | null }) {
  const [preview, setPreview] = useState<InvitePreview | null>(null);
  const [busy, setBusy] = useState(false);
  const [err, setErr] = useState<string | null>(null);
  const [done, setDone] = useState<string | null>(null);

  useEffect(() => {
    // best effort: the issuer may not allow a cross-origin read, and that is fine
    api.previewInvite(from, token).then(setPreview).catch(() => setPreview(null));
  }, [from, token]);

  const join = async () => {
    setBusy(true);
    setErr(null);
    try {
      const out = await api.redeem(from, token);
      setDone(out.joined.node);
      setTimeout(() => location.assign("/admin?tab=members"), 1200);
    } catch (e) {
      setErr((e as Error).message);
      setBusy(false);
    }
  };

  if (done)
    return (
      <Shell>
        <Head title={`joined ${done}`} sub="taking you to members…" />
      </Shell>
    );

  return (
    <Shell>
      <Head title={`join ${preview?.node ?? from}?`} sub={`this node is ${status?.node ?? "…"}`} />
      <div className="px-4 py-3 text-[11px] leading-relaxed text-dim">
        <div className="text-fg">{preview ? `${preview.node} · key ${preview.fingerprint}` : from}</div>
        <p className="pt-2">
          You will share this node's agent roster with them and accept their messages. They will be able to send text
          into panes on this machine. You can kick them from the admin page at any time.
        </p>
        {preview?.note && <p className="pt-2 text-dim">“{preview.note}”</p>}
      </div>
      {err && <div className="px-4 pb-2 text-[11px] text-bad">{err}</div>}
      <div className="flex gap-2 border-t border-edge bg-[#0f1218] px-4 py-3">
        <a href="/" className="rounded px-3 py-1.5 text-faint hover:text-fg">
          cancel
        </a>
        <button
          onClick={join}
          disabled={busy}
          className="ml-auto rounded-md bg-accent px-4 py-1.5 font-semibold text-[#07131d] hover:bg-[#7cc3ff] disabled:bg-[#22364a] disabled:text-faint"
        >
          {busy ? "redeeming…" : "join"}
        </button>
      </div>
    </Shell>
  );
}

export function JoinLanding({ status }: { status: Status | null }) {
  const params = new URLSearchParams(location.search);
  const from = params.get("from");
  const t = params.get("t");
  if (from && t) return <Confirm from={from} token={t} status={status} />;

  const token = decodeURIComponent(location.pathname.replace(/^\/join\/?/, ""));
  if (!token) return <Shell><Head title="no invite in this link" sub="an invite looks like /join/<secret>" /></Shell>;
  return <Invitation token={token} />;
}

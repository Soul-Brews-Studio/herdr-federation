import { useState } from "react";
import type { AuditEntry } from "../../types";

/**
 * The process, not a description of it.
 *
 * Every membership change the server makes records the steps it actually took,
 * including the ones that failed. This renders those steps. When a process has
 * never run on this node it falls back to the canonical shape, clearly marked
 * as not-yet-run, so the page never shows an invented success.
 */

const CANON: Record<string, { title: string; steps: string[] }> = {
  join: {
    title: "someone redeems our invite",
    steps: [
      "look the invite up",
      "check the invite is still good",
      "check the key is not banned",
      "verify the signature",
      "issue a member token and store the membership",
    ],
  },
  redeem: {
    title: "we redeem someone else's invite",
    steps: [
      "read the invite link",
      "mint the token we will issue them",
      "sign the request with this node's key",
      "they verified it and issued us a token",
      "store the membership and start syncing",
    ],
  },
  kick: {
    title: "we kick a member",
    steps: [
      "delete the membership",
      "their token stops authenticating",
      "stop pushing and pulling with them",
      "publish the kick",
    ],
  },
};

/**
 * The two join flows share an action; the first step says which side we were on.
 * A ban is deliberately not folded in here — it records its own two steps, and
 * showing them under "we kick a member" would mislabel what they say.
 */
const flowOf = (e: AuditEntry): keyof typeof CANON | null => {
  if (e.action === "member.join") return e.steps[0]?.label === "read the invite link" ? "redeem" : "join";
  if (e.action === "member.kick" || e.action === "kick.adopt") return "kick";
  return null;
};

const time = (iso: string) => new Date(iso).toLocaleTimeString([], { hour: "2-digit", minute: "2-digit", second: "2-digit" });
const when = (iso: string) => new Date(iso).toLocaleString([], { month: "short", day: "numeric", hour: "2-digit", minute: "2-digit", second: "2-digit" });

const ago = (iso: string) => {
  const s = Math.round((Date.now() - Date.parse(iso)) / 1000);
  if (s < 60) return `${s}s ago`;
  if (s < 3600) return `${Math.round(s / 60)}m ago`;
  if (s < 86400) return `${Math.round(s / 3600)}h ago`;
  return `${Math.round(s / 86400)}d ago`;
};

/** Did the run get all the way through? A failed run stops at the step that refused. */
const failedAt = (e: AuditEntry) => e.steps.find((s) => !s.ok);

/**
 * One line that tells two runs apart. Two joins from the same node, seconds
 * apart, are identical on a wall clock — which invite they spent is the thing
 * that actually differs, so the server stamps that on the entry.
 */
const describe = (e: AuditEntry) => e.summary ?? e.reason ?? "";

function Flow({ flow, runs }: { flow: keyof typeof CANON; runs: AuditEntry[] }) {
  const [pick, setPick] = useState(0);
  const run = runs[Math.min(pick, runs.length - 1)];
  const bad = run ? failedAt(run) : undefined;
  const canon = CANON[flow];
  const steps = run
    ? run.steps
    : canon.steps.map((label, i) => ({ n: i + 1, label, ok: true, detail: undefined, wire: undefined }));

  return (
    <section className="min-w-0 rounded-lg border border-edge bg-panel">
      <header className="border-b border-edge px-3 py-2">
        <div className="flex flex-wrap items-baseline gap-2">
          <b className="font-semibold">{canon.title}</b>
          {run ? (
            <span className={`rounded px-1.5 py-px text-[10px] ${bad ? "bg-[#3a1b1b] text-bad" : "bg-[#14301f] text-ok"}`}>
              {bad ? `failed · ${bad.label}` : "completed"}
            </span>
          ) : (
            <span className="text-[11px] text-faint">has not happened on this node yet</span>
          )}
          {runs.length > 1 && (
            <select
              value={pick}
              onChange={(e) => setPick(Number(e.target.value))}
              aria-label="pick a run"
              className="ml-auto max-w-[min(60%,22rem)] truncate rounded border border-edge-bright bg-[#0b0e13] px-1.5 py-0.5 text-[11px] text-dim"
            >
              {runs.map((r, i) => (
                <option key={r.id} value={i}>
                  {failedAt(r) ? "✕" : "✓"} {time(r.at)} · {r.node}
                  {describe(r) ? ` · ${describe(r)}` : ""}
                </option>
              ))}
            </select>
          )}
        </div>

        {run && (
          <div className="pt-0.5 text-[11px] text-faint">
            <b className="font-normal text-dim">{run.node}</b> · {when(run.at)} · {ago(run.at)} ·{" "}
            <span title="audit entry id">#{run.id}</span>
            {describe(run) && <> · {describe(run)}</>}
            {runs.length > 1 && (
              <>
                {" "}
                · run {pick + 1} of {runs.length}
              </>
            )}
          </div>
        )}
      </header>

      <ol className="px-3 py-2">
        {steps.map((s) => (
          <li key={s.n} className="grid grid-cols-[18px_1fr] gap-2 py-1">
            <span
              className={`mt-[3px] grid h-[18px] w-[18px] place-items-center self-start rounded-full text-[10px] ${
                !run ? "bg-[#1a1e27] text-faint" : s.ok ? "bg-[#14301f] text-ok" : "bg-[#3a1b1b] text-bad"
              }`}
            >
              {!run ? s.n : s.ok ? "✓" : "✕"}
            </span>
            <div className="min-w-0">
              <div className={s.ok ? "" : "text-bad"}>{s.label}</div>
              {s.detail && <div className="break-words text-[11px] text-faint">{s.detail}</div>}
              {s.wire && <div className="break-all text-[11px] text-accent-dim">{s.wire}</div>}
            </div>
          </li>
        ))}
      </ol>

      {run?.reason && run.reason !== run.summary && (
        <div className="border-t border-edge px-3 py-1.5 text-[11px] text-warn">reason: {run.reason}</div>
      )}
    </section>
  );
}

export function ProcessView({ audit }: { audit: AuditEntry[] }) {
  const runs = (flow: keyof typeof CANON) => audit.filter((e) => flowOf(e) === flow).slice(0, 8);
  return (
    <div className="grid gap-3 md:grid-cols-2">
      <Flow flow="join" runs={runs("join")} />
      <Flow flow="redeem" runs={runs("redeem")} />
      <Flow flow="kick" runs={runs("kick")} />
      <section className="min-w-0 rounded-lg border border-edge bg-panel p-3 text-[11px] leading-relaxed text-dim">
        <b className="text-fg">what a kick can and cannot do</b>
        <p className="pt-1.5">
          A kick is enforced <b className="text-fg">on this node only</b>. It deletes the membership, so their token
          stops authenticating here and their next call to <code className="text-accent-dim">/api/fed/*</code> answers
          401. It does not and cannot remove them from anyone else's node.
        </p>
        <p className="pt-1.5">
          There is no server above these nodes, so a mesh-wide kick would mean every node obeying any other node —
          and one compromised node could then empty the mesh with nobody entitled to refuse. Kicks are published
          instead: peers see them and adopt them with a click, the way a Matrix homeserver keeps its own ACL.
        </p>
        <p className="pt-1.5">
          <b className="text-fg">Kick</b> lets them return through any invite that is still valid.{" "}
          <b className="text-fg">Ban</b> pins their key, so no invite helps.
        </p>
      </section>
    </div>
  );
}

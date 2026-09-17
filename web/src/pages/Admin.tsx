import { useCallback, useEffect, useState } from "react";
import { api } from "../api";
import { AuditLog } from "../components/admin/AuditLog";
import { InvitesTable } from "../components/admin/InvitesTable";
import { BansTable, MembersTable } from "../components/admin/MembersTable";
import { MeshMap } from "../components/admin/MeshMap";
import { ProcessView } from "../components/admin/ProcessView";
import type { AdminState } from "../types";

/**
 * Federation management for THIS node.
 *
 * The page shows the whole mesh and acts only on the node that served it. That
 * is not a limitation of the UI — it is the trust model: there is no server
 * above these nodes, so nothing here can speak for anyone else's door.
 */

const TABS = ["overview", "map", "members", "invites", "bans", "audit"] as const;
type Tab = (typeof TABS)[number];

export function Admin() {
  const [state, setState] = useState<AdminState | null>(null);
  const [tab, setTab] = useState<Tab>(() => {
    const want = new URLSearchParams(location.search).get("tab");
    return (TABS as readonly string[]).includes(want ?? "") ? (want as Tab) : "overview";
  });
  const [err, setErr] = useState<string | null>(null);

  const load = useCallback(async () => {
    try {
      setState(await api.admin());
      setErr(null);
    } catch (e) {
      setErr((e as Error).message);
    }
  }, []);

  useEffect(() => {
    void load();
    const id = setInterval(load, 3000);
    return () => clearInterval(id);
  }, [load]);

  // the tab is in the URL, so a reload and the back button both land where you were
  const go = (next: Tab) => {
    setTab(next);
    history.pushState(null, "", next === "overview" ? "/admin" : `/admin?tab=${next}`);
  };
  useEffect(() => {
    const onPop = () => {
      const want = new URLSearchParams(location.search).get("tab");
      setTab((TABS as readonly string[]).includes(want ?? "") ? (want as Tab) : "overview");
    };
    addEventListener("popstate", onPop);
    return () => removeEventListener("popstate", onPop);
  }, []);

  if (!state)
    return (
      <div className="grid h-full place-content-center text-[11px] text-faint">{err ? `admin unavailable — ${err}` : "…"}</div>
    );

  const unverified = state.members.filter((m) => m.legacy).length;

  return (
    <div className="grid h-dvh grid-rows-[auto_auto_1fr] bg-bg">
      <header className="flex flex-wrap items-baseline gap-3 border-b border-edge bg-rail px-4 py-2.5">
        <a href="/" className="text-faint hover:text-accent">
          ‹ console
        </a>
        <b className="font-semibold">federation · {state.node}</b>
        <span className="text-[11px] text-faint" title={state.identity.pubkey}>
          key {state.identity.fingerprint}
        </span>
        <span className="ml-auto text-[11px] text-faint">
          {state.members.length} members · {state.invites.filter((i) => i.status === "active").length} live invites ·{" "}
          {state.bans.length} bans
        </span>
      </header>

      {state.legacyAllowed && (
        <div className="border-b border-warn/40 bg-[#241d0c] px-4 py-1.5 text-[11px] text-warn">
          <b>FED_ALLOW_LEGACY is on.</b> Requests with no member token are still accepted, so a kick does not fully
          close the door yet
          {unverified ? ` (${unverified} unverified peer${unverified > 1 ? "s" : ""})` : ""}. Re-invite every peer, then
          restart with <code>FED_ALLOW_LEGACY=0</code>.
        </div>
      )}

      <div className="grid min-h-0 grid-cols-[150px_1fr]">
        <nav className="border-r border-edge bg-rail py-2">
          {TABS.map((t) => (
            <button
              key={t}
              onClick={() => go(t)}
              className={`block w-full px-4 py-1.5 text-left ${
                tab === t ? "bg-[#1d2532] text-accent" : "text-faint hover:bg-[#161b24] hover:text-dim"
              }`}
            >
              {t}
            </button>
          ))}
        </nav>

        <main className="min-w-0 overflow-auto p-4">
          {tab === "overview" && <ProcessView audit={state.audit} />}
          {tab === "map" && <MeshMap state={state} />}
          {tab === "members" && <MembersTable state={state} onChanged={load} />}
          {tab === "invites" && <InvitesTable state={state} onChanged={load} />}
          {tab === "bans" && <BansTable bans={state.bans} onChanged={load} />}
          {tab === "audit" && <AuditLog audit={state.audit} />}
        </main>
      </div>
    </div>
  );
}

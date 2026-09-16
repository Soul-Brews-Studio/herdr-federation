import { lazy, Suspense, useEffect, useState } from "react";
import type { Located, Status } from "../types";
import { allMembers } from "../lib";
import { MachinesTree, IconButton } from "../components/MachinesTree";
import { PaneView } from "../components/PaneView";
// xterm is the single biggest dependency here; it arrives only if you switch to it
const XtermView = lazy(() => import("../components/XtermView").then((m) => ({ default: m.XtermView })));
import { PaneChrome } from "../components/PaneChrome";
import { HeyBar } from "../components/HeyBar";
import { Control, Watch, X } from "../components/Icons";
import { CommandPalette } from "../components/CommandPalette";
const FederationPanel = lazy(() => import("../components/FederationPanel").then((m) => ({ default: m.FederationPanel })));
import { CallsRail } from "../components/CallsRail";
import { AgentMenu, type MenuTarget } from "../components/AgentMenu";

type Tab = { member: Located; interactive: boolean };
const tabKey = (t: Tab) => `${t.member.node}/${t.member.pane}/${t.interactive ? "rw" : "ro"}`;

/** /t/<node>/<pane>/<ro|rw> — a reload restores the view, back walks the tabs */
function readRoute() {
  const m = location.pathname.match(/^\/t\/([^/]+)\/([^/]+)\/(ro|rw)$/);
  return m ? { node: decodeURIComponent(m[1]), pane: decodeURIComponent(m[2]), interactive: m[3] === "rw" } : null;
}
const routeOf = (t: Tab) =>
  `/t/${encodeURIComponent(t.member.node)}/${encodeURIComponent(t.member.pane)}/${t.interactive ? "rw" : "ro"}`;

export function Console({ status }: { status: Status | null }) {
  const [tabs, setTabs] = useState<Tab[]>([]);
  const [active, setActive] = useState<string | null>(null);
  const [fedOpen, setFedOpen] = useState(false);
  const [menu, setMenu] = useState<MenuTarget | null>(null);
  // two renderers: a plain-text mirror, and the real terminal
  const [mode, setMode] = useState<"text" | "terminal">(
    () => (localStorage.getItem("fed.render") as "text" | "terminal") ?? "text",
  );
  const [full, setFull] = useState(false);

  useEffect(() => localStorage.setItem("fed.render", mode), [mode]);

  useEffect(() => {
    const onKey = (e: KeyboardEvent) => {
      if (e.key === "Escape") setFull(false);
      if (e.key === "f" && (e.metaKey || e.ctrlKey) && e.shiftKey) {
        e.preventDefault();
        setFull((v) => !v);
      }
    };
    addEventListener("keydown", onKey);
    return () => removeEventListener("keydown", onKey);
  }, []);

  function open(tab: Tab, push = true) {
    setTabs((prev) => (prev.some((t) => tabKey(t) === tabKey(tab)) ? prev : [...prev, tab]));
    setActive(tabKey(tab));
    if (push) history.pushState({}, "", routeOf(tab));
  }

  // restore whatever the URL points at, once the roster knows about that pane
  useEffect(() => {
    const route = readRoute();
    if (!route || !status || tabs.length) return;
    const member = allMembers(status).find((m) => m.node === route.node && m.pane === route.pane);
    if (member) open({ member, interactive: route.interactive }, false);
  }, [status]);

  useEffect(() => {
    const onPop = () => {
      const route = readRoute();
      setActive(route ? `${route.node}/${route.pane}/${route.interactive ? "rw" : "ro"}` : null);
    };
    addEventListener("popstate", onPop);
    return () => removeEventListener("popstate", onPop);
  }, []);

  function close(key: string) {
    setTabs((prev) => {
      const next = prev.filter((t) => tabKey(t) !== key);
      if (active === key) {
        const last = next.at(-1);
        setActive(last ? tabKey(last) : null);
        history.pushState({}, "", last ? routeOf(last) : "/");
      }
      return next;
    });
  }

  const current = tabs.find((t) => tabKey(t) === active);

  return (
    <div className="grid grid-cols-[300px_1fr] h-full min-h-0">
      <CommandPalette status={status} onPick={(m, interactive) => open({ member: m, interactive })} />
      {fedOpen && (
        <Suspense fallback={null}>
          <FederationPanel status={status} onClose={() => setFedOpen(false)} />
        </Suspense>
      )}
      <AgentMenu
        target={menu}
        onClose={() => setMenu(null)}
        onWatch={(m) => open({ member: m, interactive: false })}
        onControl={(m) => open({ member: m, interactive: true })}
      />
      <MachinesTree
        status={status}
        here="console"
        currentPane={current?.member.pane}
        onPick={(m) => open({ member: m, interactive: false })}
        onMenu={(m, at) => setMenu({ member: m, ...at })}
        actions={(m) => (
          <>
            <IconButton title="watch (read-only)" onClick={() => open({ member: m, interactive: false })}>
              <Watch className="w-[13px] h-[13px]" />
            </IconButton>
            <IconButton title="type into this pane" onClick={() => open({ member: m, interactive: true })}>
              <Control className="w-[13px] h-[13px]" />
            </IconButton>
          </>
        )}
        footer={
          <>
            <button onClick={() => setFedOpen(true)} className="text-faint hover:text-accent">
              federation · {status?.peers?.length ?? 0}
            </button>
            <span className="ml-auto text-[#4b5261]">⌘K</span>
          </>
        }
      />

      <main className="grid grid-rows-[auto_1fr_auto_auto_auto] min-w-0 min-h-0">
        <div className="flex items-stretch gap-1.5 border-b border-edge px-3 pt-2">
          {tabs.map((t, i) => {
            const key = tabKey(t);
            const on = key === active;
            return (
              <button
                key={key}
                onClick={() => {
                  setActive(key);
                  history.pushState({}, "", routeOf(t));
                }}
                className={`-mb-px inline-flex max-w-[320px] items-center gap-2 rounded-t-md border border-b-0 px-2.5 py-1.5 ${
                  on
                    ? "border-accent bg-bg text-fg shadow-[inset_0_2px_0_var(--color-accent)]"
                    : "border-edge-bright bg-panel text-dim"
                }`}
              >
                <span className="text-accent">{i + 1}</span>
                <span className="truncate">
                  {t.member.handle}
                  {mode === "terminal" || t.interactive ? "" : " ·ro"}
                </span>
                <span
                  onClick={(e) => {
                    e.stopPropagation();
                    close(key);
                  }}
                  className="text-faint hover:text-bad"
                >
                  <X className="w-3 h-3" />
                </span>
              </button>
            );
          })}
          <span className="flex-1 -mb-px border-b border-edge" />
        </div>

        <div
          className={
            full && current
              ? "fixed inset-0 z-40 grid grid-rows-[auto_1fr] bg-bg"
              : "relative m-2.5 grid min-h-0 grid-rows-[auto_1fr] overflow-hidden rounded-md border border-edge-bright"
          }
        >
          {current && (
            <div className="absolute right-2 top-2 z-10 flex items-center gap-1 rounded-md border border-edge-bright bg-[#0d1119e0] px-1 py-0.5 text-[11px]">
              {(["text", "terminal"] as const).map((m2) => (
                <button
                  key={m2}
                  onClick={() => setMode(m2)}
                  className={`rounded px-2 py-0.5 ${mode === m2 ? "bg-[#1d2532] text-accent" : "text-faint hover:text-dim"}`}
                >
                  {m2}
                </button>
              ))}
              <button onClick={() => setFull((v) => !v)} title="full screen (⇧⌘F, esc to exit)" className="px-2 py-0.5 text-faint hover:text-fg">
                {full ? "exit" : "full"}
              </button>
            </div>
          )}
          {current && (
            <PaneChrome
              status={status}
              member={current.member}
              onPick={(m) => open({ member: m, interactive: current.interactive })}
            />
          )}
          {current ? (
            mode === "terminal" ? (
              // a terminal you cannot type into is not a terminal: terminal mode is
              // always live, whichever way the tab was opened
              <Suspense
                fallback={
                  <div className="grid h-full place-content-center text-[11px] text-faint">
                    <span className="animate-pulse">loading the terminal…</span>
                  </div>
                }
              >
                <XtermView key={`x-${tabKey(current)}`} member={current.member} interactive className="h-full" />
              </Suspense>
            ) : (
              <PaneView key={tabKey(current)} member={current.member} interactive={current.interactive} className="h-full" />
            )
          ) : (
            <div className="grid h-full place-content-center justify-items-center gap-2 p-6 text-center text-faint">
              <Control className="w-6 h-6 text-[#39404e]" />
              <b className="font-medium text-dim">pick an agent to watch its pane</b>
              <span className="text-[11px]">streamed off the herdr socket · terminal mode types straight into the pane</span>
            </div>
          )}
        </div>

        <CallsRail status={status} />

        <HeyBar status={status} />
      </main>
    </div>
  );
}

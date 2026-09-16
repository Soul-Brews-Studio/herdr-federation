import { useEffect, useState } from "react";
import type { BroadcastResult, Located, Squad, Status } from "../types";
import { api } from "../api";
import { allMembers, memberId } from "../lib";
import { MachinesTree, IconButton } from "../components/MachinesTree";
import { PaneView } from "../components/PaneView";
import { Plus, Send, X } from "../components/Icons";
import { CommandPalette } from "../components/CommandPalette";
import { AgentMenu, type MenuTarget } from "../components/AgentMenu";

const KEY = "fed.squads.v2";
const load = (): Squad[] => {
  try {
    const saved = JSON.parse(localStorage.getItem(KEY) ?? "[]") as Squad[];
    if (saved.length) return saved;
  } catch {
    /* fall through to a fresh squad */
  }
  return [{ id: `s${Date.now()}`, name: "squad 1", members: [] }];
};

/**
 * Drag agents from any machine into a squad; one message goes to all of them.
 * Every member shows its live pane, so you watch the whole squad react at once.
 */
export function Squads({ status }: { status: Status | null }) {
  const [squads, setSquads] = useState<Squad[]>(load);
  const [dragging, setDragging] = useState<Located | null>(null);
  const [over, setOver] = useState<string | null>(null);
  const [text, setText] = useState<Record<string, string>>({});
  const [busy, setBusy] = useState<string | null>(null);
  const [results, setResults] = useState<Record<string, BroadcastResult[]>>({});
  const [menu, setMenu] = useState<MenuTarget | null>(null);

  useEffect(() => localStorage.setItem(KEY, JSON.stringify(squads)), [squads]);

  /**
   * Stored members are re-resolved against the live roster every tick: a pane id
   * changes when an agent restarts, and squads saved before panes were recorded
   * carry none at all. Matching on node+handle heals both.
   */
  const roster = allMembers(status);
  const live = (m: Located): Located =>
    roster.find((r) => r.node === m.node && (r.pane === m.pane || r.handle === m.handle)) ?? m;

  const taken = new Set(squads.flatMap((s) => s.members.map((m) => memberId(live(m)))));

  const update = (id: string, fn: (s: Squad) => Squad) => setSquads((prev) => prev.map((s) => (s.id === id ? fn(s) : s)));

  function addTo(squadId: string, m: Located) {
    update(squadId, (s) => (s.members.some((x) => memberId(x) === memberId(m)) ? s : { ...s, members: [...s.members, m] }));
  }

  async function fire(squad: Squad, e: React.FormEvent) {
    e.preventDefault();
    const body = (text[squad.id] ?? "").trim();
    if (!body || !squad.members.length) return;
    setBusy(squad.id);
    try {
      const out = await api.broadcast({
        text: body,
        targets: squad.members.map(live).map((m) => ({ handle: m.handle, pane: m.pane, node: m.node, base: m.base })),
      });
      setText((t) => ({ ...t, [squad.id]: "" }));
      setResults((r) => ({ ...r, [squad.id]: out.results }));
    } catch (err) {
      setResults((r) => ({ ...r, [squad.id]: [{ handle: "—", ok: false, error: (err as Error).message }] }));
    } finally {
      setBusy(null);
    }
  }

  return (
    <div className="grid grid-cols-[300px_1fr] h-full min-h-0">
      <CommandPalette status={status} onPick={(m) => addTo(squads[0].id, m)} />
      <AgentMenu
        target={menu}
        onClose={() => setMenu(null)}
        onWatch={(m) => location.assign(`/t/${encodeURIComponent(m.node)}/${encodeURIComponent(m.pane)}/ro`)}
        onControl={(m) => location.assign(`/t/${encodeURIComponent(m.node)}/${encodeURIComponent(m.pane)}/rw`)}
        onAddToSquad={(m) => addTo(squads[0].id, m)}
      />
      <MachinesTree
        status={status}
        here="squads"
        rowProps={(m) => ({
          draggable: true,
          onDragStart: () => setDragging(m),
          onDragEnd: () => setDragging(null),
          style: taken.has(memberId(m)) ? { opacity: 0.4 } : undefined,
        })}
        onMenu={(m, at) => setMenu({ member: m, ...at })}
        actions={(m) => (
          <IconButton title="add to the first squad" onClick={() => addTo(squads[0].id, m)}>
            <Plus className="w-[13px] h-[13px]" />
          </IconButton>
        )}
        footer={<span>drag an agent into a squad</span>}
      />

      <div className="grid auto-rows-min content-start gap-3.5 overflow-y-auto min-h-0 min-w-0 p-4">
        {squads.map((squad) => (
          <section
            key={squad.id}
            onDragOver={(e) => {
              if (!dragging) return;
              e.preventDefault();
              setOver(squad.id);
            }}
            onDragLeave={() => setOver((o) => (o === squad.id ? null : o))}
            onDrop={(e) => {
              e.preventDefault();
              if (dragging) addTo(squad.id, dragging);
              setOver(null);
            }}
            className={`min-w-0 rounded-lg border bg-panel ${
              over === squad.id ? "border-accent bg-[#141b25] shadow-[0_10px_26px_-16px_rgba(0,0,0,.95)]" : "border-edge"
            }`}
          >
            <div className="flex items-center gap-2.5 border-b border-edge px-3 py-2.5">
              <input
                value={squad.name}
                onChange={(e) => update(squad.id, (s) => ({ ...s, name: e.target.value }))}
                aria-label="squad name"
                className="min-w-[60px] border-0 bg-transparent font-semibold text-fg outline-none"
              />
              <span className="text-[11px] text-faint">
                {squad.members.length} agent{squad.members.length === 1 ? "" : "s"}
              </span>
              <span className="ml-3 flex items-center gap-1 text-[11px] text-faint">
                grid
                {[0, 1, 2, 3].map((n) => (
                  <button
                    key={n}
                    onClick={() => update(squad.id, (s2) => ({ ...s2, cols: n }))}
                    title={n === 0 ? "fit to width" : `${n} across`}
                    className={`rounded px-1.5 py-0.5 ${
                      (squad.cols ?? 0) === n ? "bg-[#1d2532] text-accent" : "hover:bg-[#161b24] hover:text-dim"
                    }`}
                  >
                    {n === 0 ? "auto" : n}
                  </button>
                ))}
              </span>
              <button
                onClick={() => setSquads((prev) => prev.filter((s) => s.id !== squad.id))}
                title="delete squad"
                className="ml-auto text-faint hover:text-bad"
              >
                <X className="w-3.5 h-3.5" />
              </button>
            </div>

            {squad.members.length ? (
              <div
                className="grid gap-2.5 p-3"
                style={{
                  gridTemplateColumns: squad.cols
                    ? `repeat(${squad.cols}, minmax(0, 1fr))`
                    : "repeat(auto-fit, minmax(min(100%, 430px), 1fr))",
                }}
              >
                {squad.members.map(live).map((m) => (
                  <div key={memberId(m)} className="min-w-0 overflow-hidden rounded-md border border-edge-bright">
                    <div className="flex items-center gap-2 border-b border-edge bg-[#0f131a] px-2.5 py-1.5 text-[11px]">
                      <span className="truncate text-dim">{m.handle}</span>
                      <span className="text-faint">{m.node}</span>
                      <button
                        onClick={() => update(squad.id, (s) => ({ ...s, members: s.members.filter((x) => memberId(x) !== memberId(m)) }))}
                        className="ml-auto text-faint hover:text-bad"
                        title="remove"
                      >
                        <X className="w-3 h-3" />
                      </button>
                    </div>
                    <PaneView member={m} dense className="h-[min(42vh,400px)]" />
                  </div>
                ))}
              </div>
            ) : (
              <div className="grid min-h-[76px] place-content-center p-3 text-[11px] text-[#4b5261]">drag agents here</div>
            )}

            <form onSubmit={(e) => fire(squad, e)} className="grid grid-cols-[1fr_auto] gap-2.5 border-t border-edge bg-[#0f1218] px-3 py-2.5">
              <input
                type="text"
                value={text[squad.id] ?? ""}
                onChange={(e) => setText((t) => ({ ...t, [squad.id]: e.target.value }))}
                placeholder="one message · goes to every agent in this squad"
                aria-label="broadcast message"
                className="min-w-0 rounded-md border border-edge-bright bg-[#0b0e13] px-2.5 py-1.5 placeholder:text-[#545c6a]"
              />
              <button
                type="submit"
                disabled={!squad.members.length || busy === squad.id}
                className="inline-flex items-center gap-2 whitespace-nowrap rounded-md bg-accent px-4 py-1.5 font-semibold text-[#07131d] hover:bg-[#7cc3ff] disabled:cursor-not-allowed disabled:bg-[#22364a] disabled:text-faint"
              >
                <Send className="w-[13px] h-[13px]" />
                {busy === squad.id ? "sending…" : `send to ${squad.members.length}`}
              </button>
            </form>

            {results[squad.id] && (
              <div className="grid gap-0.5 px-3 pb-2.5 text-[11px] text-dim">
                {results[squad.id].filter((r) => r.ok).length > 0 && (
                  <div>
                    delivered to <b className="font-medium text-ok">{results[squad.id].filter((r) => r.ok).length}</b>/
                    {results[squad.id].length} · {results[squad.id].filter((r) => r.ok).map((r) => r.handle).join(", ")}
                  </div>
                )}
                {results[squad.id]
                  .filter((r) => !r.ok)
                  .map((r, i) => (
                    <div key={i} className="text-bad">
                      {r.handle} — {r.error}
                    </div>
                  ))}
              </div>
            )}
          </section>
        ))}

        <button
          onClick={() => setSquads((prev) => [...prev, { id: `s${Date.now()}`, name: `squad ${prev.length + 1}`, members: [] }])}
          className="rounded-lg border border-dashed border-edge-bright p-3.5 text-faint hover:border-accent-dim hover:text-dim"
        >
          + new squad
        </button>
      </div>
    </div>
  );
}

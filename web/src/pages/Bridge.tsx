import { useEffect, useMemo, useState } from "react";
import "../bridge.css";
import { api } from "../api";
import { Telegraph } from "../bridge/Telegraph";
import { WatchBoard, type Station } from "../bridge/WatchBoard";
import { PaneView } from "../components/PaneView";
import { useStatus } from "../useStatus";
import type { AdminState, Located } from "../types";
import { allMembers, byMachine } from "../lib";

/**
 * The bridge of the ship.
 *
 * THESIS: a federation console whose instruments cannot report agreement that
 * does not exist. It refuses the fleet-dashboard arrangement — a grid of equal
 * cards over a dark ground — because equal cards flatten the one asymmetry that
 * matters here: what this node ordered versus what the far end answered.
 *
 * OWN-WORLD: iron hull, aged brass, bone dial faces. Three ground values, one
 * metal, and two signal colours that mean exactly one thing each — order is what
 * we rang, answer is what came back. Engraved condensed caps for every plate
 * label; monospace only where there is a measurement. No radius on any
 * instrument; bezels and detents are drawn, never typed.
 *
 * STORY: the operator opens this beside a terminal at night, reads the watch
 * board for a lamp that changed, rings an order to one agent or to all of them,
 * and watches the answer needles settle.
 *
 * FIRST VIEWPORT: watch board holding the left third, floor to ceiling, stations
 * grouped by machine under engraved headers. The telegraph row sits top-right at
 * dial scale — one instrument per peer, never shrunk to an icon. The selected
 * agent's live pane fills the remaining right, with the order line pinned to its
 * bottom edge where the hands already are.
 *
 * FORM: engine-room telegraph and watch board; candidate 7 of 7 on my grounded
 * list, assigned by the roll. Seed key e27a57ae.
 *
 * FINISH: unreviewed and undocumented is unfinished; this build ends with the
 * finish review, the verdict, DESIGN.md, and every shipping raster carrying its
 * provenance.
 */
export function Bridge() {
  const status = useStatus();
  const [admin, setAdmin] = useState<AdminState | null>(null);
  const [picked, setPicked] = useState<Located | null>(null);
  const [order, setOrder] = useState("");
  const [ringing, setRinging] = useState(false);
  const [rang, setRang] = useState<string | null>(null);

  useEffect(() => {
    document.body.classList.add("bridge");
    return () => document.body.classList.remove("bridge");
  }, []);

  useEffect(() => {
    const load = () => api.admin().then(setAdmin).catch(() => setAdmin(null));
    void load();
    const id = setInterval(load, 4000);
    return () => clearInterval(id);
  }, []);

  const everyone = useMemo(() => allMembers(status), [status]);

  // byMachine already returns machine -> repo -> members, which is the exact
  // shape a watch board wants; only the shell filter is ours. A shell is a pane
  // herdr found no agent in, and a watch board of empty stations reads as a
  // fleet twice its real size.
  const stations: Station[] = useMemo(() => {
    const out: Station[] = [];
    for (const [machine, repos] of byMachine(everyone)) {
      for (const [workspace, members] of repos) {
        const agents = members.filter((m) => m.kind && m.kind !== "shell");
        if (agents.length) out.push({ machine, workspace, agents });
      }
    }
    return out;
  }, [everyone]);

  const onWatch = stations.reduce((n, s) => n + s.agents.length, 0);
  const needing = stations.reduce(
    (n, s) => n + s.agents.filter((a) => a.status === "blocked" || a.status === "done").length, 0);

  async function ring(all: boolean) {
    const text = order.trim();
    if (!text) return;
    setRinging(true);
    try {
      if (all) {
        const targets = everyone
          .filter((m) => m.kind && m.kind !== "shell")
          .map((m) => ({ handle: m.handle, pane: m.pane, node: m.node, base: m.base }));
        const r = await api.broadcast({ targets, text });
        setRang(`rang ${r.results.filter((x) => x.ok).length}/${r.results.length} stations`);
      } else if (picked) {
        await api.hey(picked.pane, text, picked.base);
        setRang(`rang ${picked.handle}`);
      }
      setOrder("");
    } catch (e) {
      setRang((e as Error).message);
    } finally {
      setRinging(false);
      setTimeout(() => setRang(null), 4000);
    }
  }

  const edges = admin?.edges ?? [];

  return (
    <div className="grid h-dvh grid-rows-[auto_minmax(0,1fr)]">
      <header className="flex flex-wrap items-baseline gap-x-5 gap-y-1 border-b border-seam bg-iron-deep px-4 py-2.5">
        <h1 className="engrave text-[15px] text-brass-lit">{status?.node ?? "—"} · bridge</h1>
        <span className="text-[11px] text-bone-dim">{onWatch} on watch</span>
        {needing > 0 && (
          <span className="text-[11px] text-order">{needing} waiting on you</span>
        )}
        <a href="/" className="engrave ml-auto text-[11px] hover:text-brass-lit">console</a>
        <a href="/admin" className="engrave text-[11px] hover:text-brass-lit">admin</a>
      </header>

      <div className="grid min-h-0 grid-cols-[minmax(240px,1fr)_minmax(0,2.4fr)]">
        <nav className="min-h-0 overflow-y-auto border-r border-seam" aria-label="watch board">
          <WatchBoard
            stations={stations}
            selected={picked ? `${picked.node}/${picked.pane}` : undefined}
            onPick={(m, machine) => {
              const l = everyone.find((x) => x.pane === m.pane && x.node === machine);
              if (l) setPicked(l);
            }}
          />
        </nav>

        <main className="grid min-h-0 grid-rows-[auto_minmax(0,1fr)_auto]">
          <section className="flex gap-3 overflow-x-auto border-b border-seam px-4 py-3" aria-label="engine order telegraphs">
            {edges.length === 0 && (
              <p className="py-6 text-[12px] text-bone-dim">
                No peer is rigged. Create an invite on the admin page and hand out the link.
              </p>
            )}
            {edges.map((e) => (
              <Telegraph key={e.peer} edge={e} panes={e.panes} />
            ))}
          </section>

          <section className="min-h-0 overflow-hidden px-4 py-3">
            {picked ? (
              <div className="plate flex h-full min-h-0 flex-col">
                <div className="flex items-baseline gap-2.5 border-b border-seam px-3 py-1.5">
                  <span className="engrave text-[12px]">{picked.handle}</span>
                  <span className="text-[11px] text-bone-dim">{picked.node} · {picked.pane} · {picked.kind}</span>
                </div>
                <div className="min-h-0 flex-1 overflow-hidden">
                  <PaneView member={picked} interactive={false} />
                </div>
              </div>
            ) : (
              <p className="pt-10 text-center text-[12px] text-bone-dim">
                Pick a station on the watch board to see what it is saying.
              </p>
            )}
          </section>

          <section className="border-t border-seam px-4 py-3">
            <label htmlFor="order" className="engrave text-[11px]">engine order</label>
            <div className="mt-1.5 grid grid-cols-[minmax(0,1fr)_auto_auto] gap-2">
              <input
                id="order"
                value={order}
                onChange={(e) => setOrder(e.target.value)}
                onKeyDown={(e) => { if (e.key === "Enter" && !e.shiftKey) { e.preventDefault(); void ring(e.metaKey); } }}
                placeholder={picked ? `order ${picked.handle}…` : "pick a station, or ring all"}
                className="min-w-0 border border-seam bg-iron-deep px-2.5 py-1.5 text-bone placeholder:text-bone-dim/70"
              />
              <button
                onClick={() => void ring(false)}
                disabled={!picked || !order.trim() || ringing}
                className="engrave border border-brass-dim px-4 py-1.5 text-[12px] text-brass-lit transition-colors duration-150 hover:bg-brass-dim/25 disabled:border-seam disabled:text-bone-dim"
              >ring</button>
              <button
                onClick={() => void ring(true)}
                disabled={!order.trim() || ringing}
                className="engrave border border-seam px-4 py-1.5 text-[12px] text-bone-dim transition-colors duration-150 hover:border-brass-dim hover:text-brass disabled:text-bone-dim/50"
              >all stations</button>
            </div>
            <p aria-live="polite" className="mt-1.5 h-4 text-[11px] text-answer">{rang}</p>
          </section>
        </main>
      </div>
    </div>
  );
}

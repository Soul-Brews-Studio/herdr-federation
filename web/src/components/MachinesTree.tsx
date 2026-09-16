import { useState, type ReactNode } from "react";
import type { Located, Status } from "../types";
import { allMembers, byMachine, tabSize } from "../lib";
import { StatusGlyph } from "./Icons";

type Props = {
  status: Status | null;
  here: "console" | "squads";
  actions?: (m: Located) => ReactNode;
  rowProps?: (m: Located) => React.HTMLAttributes<HTMLDivElement> & { draggable?: boolean };
  onPick?: (m: Located) => void;
  /** same menu on right-click and on the ⋯ button */
  onMenu?: (m: Located, at: { x: number; y: number }) => void;
  footer?: ReactNode;
  currentPane?: string;
};

/**
 * The machines tree, shared by both pages: machine -> repo -> agents,
 * the shape herdr's own sidebar uses.
 */
const COLLAPSED_KEY = "fed.collapsed.machines";

export function MachinesTree({ status, here, actions, rowProps, onPick, onMenu, footer, currentPane }: Props) {
  const machines = byMachine(allMembers(status));

  // which machines are folded away, remembered between visits
  const [collapsed, setCollapsed] = useState<string[]>(() => {
    try {
      return JSON.parse(localStorage.getItem(COLLAPSED_KEY) ?? "[]");
    } catch {
      return [];
    }
  });

  const toggle = (node: string) =>
    setCollapsed((prev) => {
      const next = prev.includes(node) ? prev.filter((n) => n !== node) : [...prev, node];
      localStorage.setItem(COLLAPSED_KEY, JSON.stringify(next));
      return next;
    });

  return (
    <aside className="grid grid-rows-[auto_1fr_auto] min-h-0 bg-rail border-r border-edge">
      <div className="flex items-baseline gap-2.5 px-4 pt-3.5 pb-2 text-[11px] tracking-[.08em] text-faint">
        <span>machines</span>
        <nav className="ml-auto flex gap-2.5">
          <a href="/" className={`no-underline ${here === "console" ? "text-accent" : "text-faint hover:text-fg"}`}>console</a>
          <a href="/teams" className={`no-underline ${here === "squads" ? "text-accent" : "text-faint hover:text-fg"}`}>squads</a>
        </nav>
      </div>

      <div className="overflow-y-auto min-h-0 pb-2">
        {[...machines].map(([node, repos]) => {
          const peer = status?.peers?.find((p) => p.name === node);
          const local = node === status?.node;
          const dot = local || peer?.ok === true ? "bg-ok" : peer?.ok === false ? "bg-bad" : "bg-[#39404e]";
          const folded = collapsed.includes(node);
          const paneCount = [...repos.values()].reduce((n, l) => n + l.length, 0);
          return (
            <div key={node}>
              <button
                onClick={() => toggle(node)}
                title={folded ? "expand" : "collapse"}
                className="grid w-full grid-cols-[12px_1fr_auto_auto] items-center gap-2 px-4 pt-2 pb-[3px] text-left hover:bg-[#151922]"
              >
                <span className="text-[10px] text-faint">{folded ? "▸" : "▾"}</span>
                <span className="truncate text-fg">{local ? `${node}  (local)` : node}</span>
                {folded && <span className="text-[11px] text-faint">{paneCount}</span>}
                <span className={`w-[7px] h-[7px] rounded-full justify-self-end ${dot}`} />
              </button>

              {!folded && [...repos].map(([repo, list]) => (
                <div key={repo}>
                  <div className="grid grid-cols-[18px_minmax(0,1fr)_auto] items-center gap-[7px] pl-5 pr-3.5 pt-[3px] pb-px">
                    <span className="text-[11px] tracking-tighter text-[#2c333f]">├─</span>
                    <span className="truncate text-dim">{repo}</span>
                    <span className="text-[11px] text-[#4b5261]">{list.length}</span>
                  </div>

                  {list.map((m, i) => {
                    const extra = rowProps?.(m) ?? {};
                    const current = currentPane && m.pane === currentPane;
                    const split = tabSize(list, m) > 1;
                    const firstOfTab = !split || list.findIndex((x) => x.tab === m.tab) === i;
                    return (
                      <div
                        key={m.node + m.pane}
                        title={`${m.kind ?? ""}${m.where ? ` · ${m.where}` : ""}`}
                        onContextMenu={(e) => {
                          if (!onMenu) return;
                          e.preventDefault();
                          onMenu(m, { x: e.clientX, y: e.clientY });
                        }}
                        {...extra}
                        className={`group grid grid-cols-[18px_13px_minmax(0,1fr)_auto] items-center gap-[7px] w-full pl-[34px] pr-3.5 py-0.5 leading-[1.7] hover:bg-[#151922] ${
                          current ? "bg-[#16243499] shadow-[inset_2px_0_0_var(--color-accent)]" : ""
                        } ${extra.draggable ? "cursor-grab active:cursor-grabbing" : ""}`}
                      >
                        <span className="text-[11px] tracking-tighter text-[#2c333f]">
                          {split ? (firstOfTab ? "├┬" : "│└") : i === list.length - 1 ? "└─" : "├─"}
                        </span>
                        <StatusGlyph status={m.status} className="w-[11px] h-[11px] justify-self-center" />
                        <span className="flex min-w-0 items-baseline gap-1.5">
                          {onPick ? (
                            <button className="truncate text-left" onClick={() => onPick(m)}>{m.handle}</button>
                          ) : (
                            <span className="truncate">{m.handle}</span>
                          )}
                          {split && (
                            <span className="shrink-0 text-[10px] text-faint" title="shares a tab with another pane">
                              {m.kind}
                            </span>
                          )}
                        </span>
                        <span className="flex gap-0.5 justify-self-end opacity-0 transition-opacity group-hover:opacity-100 group-focus-within:opacity-100">
                          {actions?.(m)}
                          {onMenu && (
                            <button
                              title="more"
                              onClick={(e) => {
                                e.stopPropagation();
                                const r = (e.currentTarget as HTMLElement).getBoundingClientRect();
                                onMenu(m, { x: r.right + 6, y: r.top });
                              }}
                              className="inline-grid h-5 w-[18px] place-items-center rounded text-faint hover:bg-[#1f2531] hover:text-fg"
                            >
                              ⋯
                            </button>
                          )}
                        </span>
                      </div>
                    );
                  })}
                </div>
              ))}
            </div>
          );
        })}
        {!status?.peers?.length && <div className="pl-[41px] pr-4 pb-2 pt-0.5 text-[11px] text-[#4b5261]">no peers configured</div>}
      </div>

      <div className="flex gap-2.5 border-t border-edge px-4 py-2 text-[11px] text-faint">{footer}</div>
    </aside>
  );
}

export const IconButton = ({ children, ...rest }: React.ButtonHTMLAttributes<HTMLButtonElement>) => (
  <button {...rest} className="inline-grid place-items-center w-[23px] h-5 rounded text-faint hover:bg-[#1f2531] hover:text-fg">
    {children}
  </button>
);

import type { Located, Status } from "../types";
import { allMembers } from "../lib";

type Props = {
  status: Status | null;
  member: Located;
  onPick: (m: Located) => void;
};

const dot = (s?: string) =>
  s === "working" ? "bg-accent" : s === "blocked" ? "bg-warn" : s === "done" ? "bg-ok" : "bg-[#4a5260]";

/**
 * The chrome herdr itself shows around a pane, rebuilt from session.snapshot:
 * the workspace's tabs, then the panes inside the current tab.
 *
 * A tab is a group of panes; a workspace is a group of tabs bound to a worktree.
 * Flattening that away (which agent.list does) is what loses a split pane.
 */
export function PaneChrome({ status, member, onPick }: Props) {
  const topo = status?.topology;
  const local = member.node === status?.node;
  const workspace = topo?.workspaces?.find((w) => w.id === member.workspace);
  const tabs = (topo?.tabs ?? []).filter((t) => t.workspace === member.workspace);
  const all = allMembers(status).filter((m) => m.node === member.node);
  const siblings = all.filter((m) => m.tab === member.tab);

  const firstPaneOf = (tabId: string) => all.find((m) => m.tab === tabId);

  // a remote node's topology is not in this node's snapshot; show what we do know
  if (!local || !workspace) {
    return (
      <div className="flex items-baseline gap-2.5 border-b border-edge px-3 py-2">
        <span className="truncate">{member.handle}</span>
        <span className="truncate text-[11px] text-faint">
          {member.kind} · {member.repo ?? ""} · {member.node}
        </span>
      </div>
    );
  }

  return (
    <div className="border-b border-edge">
      <div className="flex items-baseline gap-2.5 px-3 pt-2">
        <span className="truncate">{member.handle}</span>
        <span className="truncate text-[11px] text-faint">
          {workspace.label}
          {workspace.linkedWorktree ? " · worktree" : ""}
          {member.where ? ` · ${member.where.replace(/^\/opt\/Code\/github\.com\//, "")}` : ""}
        </span>
        <span className="ml-auto shrink-0 text-[11px] text-faint">
          {member.kind}
          {member.scrollback ? ` · ${member.scrollback} back` : ""}
        </span>
      </div>

      {tabs.length > 1 && (
        <div className="flex gap-1.5 px-3 pt-2">
          {tabs.map((t) => {
            const on = t.id === member.tab;
            const target = firstPaneOf(t.id);
            return (
              <button
                key={t.id}
                disabled={!target}
                onClick={() => target && onPick(target)}
                className={`inline-flex items-center gap-2 rounded-md border px-2.5 py-1 text-[11px] ${
                  on ? "border-edge-bright bg-[#161d28] text-fg" : "border-transparent text-faint hover:bg-[#151922]"
                }`}
              >
                <span className={`h-[6px] w-[6px] rounded-full ${dot(t.status)}`} />
                {t.label ?? `tab ${t.number}`}
                <span className="text-[#4b5261]">{t.paneCount}</span>
              </button>
            );
          })}
        </div>
      )}

      {siblings.length > 1 && (
        <div className="flex flex-wrap gap-1.5 px-3 py-2">
          {siblings.map((p) => {
            const on = p.pane === member.pane;
            return (
              <button
                key={p.pane}
                onClick={() => onPick(p)}
                title={p.where}
                className={`inline-flex max-w-[280px] items-center gap-2 rounded-full border px-2.5 py-0.5 text-[11px] ${
                  on ? "border-accent-dim bg-[#13202e] text-fg" : "border-edge-bright text-faint hover:text-dim"
                }`}
              >
                <span className={`h-[6px] w-[6px] shrink-0 rounded-full ${dot(p.status)}`} />
                <span className="truncate">{p.handle}</span>
              </button>
            );
          })}
        </div>
      )}
      {siblings.length <= 1 && tabs.length <= 1 && <div className="pb-2" />}
    </div>
  );
}

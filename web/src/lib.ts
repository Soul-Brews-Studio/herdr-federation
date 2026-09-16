import type { Located, Status } from "./types";

/** /opt/Code/github.com/org/repo[/wt/worktree] -> { repo, worktree } */
export function place(where?: string) {
  const p = (where ?? "").replace(/^\/opt\/Code\/github\.com\//, "");
  const [, repo = "", rest = ""] = p.match(/^[^/]+\/([^/]+)(.*)$/) ?? [];
  return { repo: repo || "~", worktree: rest.match(/\/wt\/([^/]+)/)?.[1] ?? "" };
}

/** every agent on every node, each tagged with where it lives */
export function allMembers(s: Status | null): Located[] {
  if (!s) return [];
  return [
    ...(s.members ?? []).map((m) => ({ ...m, node: s.node, base: "" })),
    ...Object.entries(s.peerMembers ?? {}).flatMap(([node, list]) =>
      (list ?? []).map((m) => ({ ...m, node, base: s.peerUi?.[node] ?? "" })),
    ),
  ];
}

/**
 * machine -> repo -> panes, the shape herdr's own sidebar uses.
 * Panes of one tab stay adjacent: a split tab is two panes, not two rows that
 * happen to sort near each other.
 */
export function byMachine(members: Located[]) {
  const machines = new Map<string, Map<string, Located[]>>();
  for (const m of members) {
    const repos = machines.get(m.node) ?? new Map<string, Located[]>();
    const repo = m.repo ?? place(m.where).repo;
    repos.set(repo, [...(repos.get(repo) ?? []), m]);
    machines.set(m.node, repos);
  }
  for (const repos of machines.values())
    for (const [repo, list] of repos)
      repos.set(
        repo,
        [...list].sort((a, b) => (a.tab ?? "").localeCompare(b.tab ?? "") || a.pane.localeCompare(b.pane)),
      );
  return machines;
}

/** how many panes share this one's tab */
export const tabSize = (list: Located[], m: Located) =>
  m.tab ? list.filter((x) => x.tab === m.tab).length : 1;

export const memberId = (m: { node: string; pane: string }) => `${m.node}/${m.pane}`;

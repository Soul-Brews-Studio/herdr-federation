/**
 * The shapes herdr's socket actually returns, as observed against protocol 22.
 *
 * Kept separate from the client so both the server and anything else reading a
 * snapshot describe the same thing, and so the one place that has to trust the
 * wire — the JSON parse — is the only place a cast lives.
 */

export type AgentStatus = "idle" | "working" | "blocked" | "done" | "unknown";

export type Worktree = {
  repo_key?: string;
  repo_name?: string;
  repo_root?: string;
  checkout_path?: string;
  is_linked_worktree?: boolean;
};

export type Workspace = {
  workspace_id: string;
  number?: number;
  label?: string;
  focused?: boolean;
  pane_count?: number;
  tab_count?: number;
  active_tab_id?: string;
  agent_status?: AgentStatus;
  worktree?: Worktree;
};

export type Tab = {
  tab_id: string;
  workspace_id: string;
  number?: number;
  label?: string;
  focused?: boolean;
  pane_count?: number;
  agent_status?: AgentStatus;
};

export type Scroll = {
  offset_from_bottom?: number;
  max_offset_from_bottom?: number;
  viewport_rows?: number;
};

export type Pane = {
  pane_id: string;
  terminal_id?: string;
  workspace_id?: string;
  tab_id?: string;
  focused?: boolean;
  cwd?: string;
  foreground_cwd?: string;
  agent?: string;
  agent_name?: string | null;
  label?: string;
  terminal_title?: string;
  terminal_title_stripped?: string;
  agent_status?: AgentStatus;
  scroll?: Scroll;
  revision?: number;
};

export type Agent = Pane & { agent: string };

export type Snapshot = {
  version?: number;
  protocol?: number;
  focused_workspace_id?: string;
  focused_tab_id?: string;
  focused_pane_id?: string;
  workspaces: Workspace[];
  tabs: Tab[];
  panes: Pane[];
  agents: Agent[];
};

/** `pane.read` — `visible` reads carry a revision of 0; diff on the text. */
export type PaneRead = {
  pane_id: string;
  workspace_id?: string;
  tab_id?: string;
  source: string;
  format: string;
  text: string;
  revision?: number;
  truncated?: boolean;
};

export type SocketError = { code: string; message: string };

/** Envelope: one request, one reply, then the server closes. */
export type Reply<T> = { id: string; result?: T; error?: SocketError };

export type Methods = {
  "session.snapshot": { params: Record<string, never>; result: { type: "session_snapshot"; snapshot: Snapshot } };
  "agent.list": { params: Record<string, never>; result: { type: "agent_list"; agents: Agent[] } };
  "pane.list": { params: Record<string, never>; result: { type: "pane_list"; panes: Pane[] } };
  "workspace.list": { params: Record<string, never>; result: { type: "workspace_list"; workspaces: Workspace[] } };
  "pane.read": {
    params: { pane_id: string; source: string; lines: number; format: string };
    result: { type: "pane_read"; read: PaneRead } | PaneRead;
  };
  "pane.send_text": { params: { pane_id: string; text: string }; result: { type: string } };
  "pane.send_keys": { params: { pane_id: string; keys: string[] }; result: { type: string } };
};

export type Method = keyof Methods;
export type Params<M extends Method> = Methods[M]["params"];
export type Result<M extends Method> = Methods[M]["result"];

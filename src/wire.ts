/**
 * The HTTP/WS contract between a node and its console — and between nodes.
 *
 * One definition, imported by the server and by the web app (Vite aliases it),
 * so a shape can never drift between the end that sends it and the end that
 * reads it.
 */

import type { AgentStatus } from "./protocol";

/** A pane as the console sees it: herdr's topology, flattened just enough to render. */
export type Member = {
  handle: string;
  kind: string;
  where?: string;
  status?: AgentStatus;
  pane: string;
  terminal?: string;
  focused?: boolean;
  revision?: number;
  /** how far this pane's scrollback goes, and how tall its viewport is */
  scrollback?: number;
  rows?: number;
  /** a tab can hold several panes side by side */
  tab?: string;
  workspace?: string;
  workspaceLabel?: string;
  repo?: string;
};

export type UiWorkspace = {
  id: string;
  label?: string;
  number?: number;
  status?: AgentStatus;
  paneCount?: number;
  repo?: string;
  checkout?: string;
  linkedWorktree?: boolean;
};

export type UiTab = {
  id: string;
  workspace: string;
  label?: string;
  number?: number;
  status?: AgentStatus;
  paneCount?: number;
};

export type Topology = { workspaces: UiWorkspace[]; tabs: UiTab[] };

export type PeerView = {
  name: string;
  url: string;
  via?: string;
  ok?: boolean;
  lastError?: string;
  lastSeen?: string;
};

export type KnownNode = { node: string; url?: string; lastHeard: string };

export type FedMessage = {
  /** origin node + per-node sequence: stable across relays, so dedup is exact */
  id: string;
  node: string;
  seq: number;
  from: string;
  text: string;
  at: string;
};

export type Invite = {
  node: string;
  session: string | null;
  socket: string;
  url: string | null;
  hint: string | null;
};

export type Stats = { pushed: number; pulled: number; errors: number; startedAt: string };

/** GET /api/status */
export type StatusResponse = {
  node: string;
  session: string | null;
  invite: Invite;
  topology: Topology;
  gossip: boolean;
  stats: Stats;
  members: Member[];
  messages: FedMessage[];
  peers: PeerView[];
  peerMembers: Record<string, Member[]>;
  peerUi: Record<string, string>;
  known: KnownNode[];
};

/** GET /api/calls */
export type CallRecord = {
  at: string;
  method: string;
  params: Readonly<Record<string, unknown>>;
  /** the command line that would do the same by hand, where one exists */
  cli: string | null;
  ms: number;
  ok: boolean;
  error?: string;
};
export type CallsResponse = { calls: CallRecord[] };

/** POST /api/hey */
export type HeyRequest = { to?: string; text?: string };
export type HeyResponse = { delivered: "pane" | "channel"; to?: string; pane?: string; id?: string };

/** POST /api/broadcast */
export type BroadcastTarget = { handle: string; pane?: string; node?: string; base?: string };
export type BroadcastRequest = { targets?: BroadcastTarget[]; text?: string };
export type BroadcastResult = {
  handle: string;
  node?: string;
  ok: boolean;
  via?: "local" | "peer";
  error?: string;
};
export type BroadcastResponse = { results: BroadcastResult[] };

/** POST /api/peers/join · /api/peers/leave */
export type JoinRequest = { url?: string };
export type JoinResponse = { joined: { node: string; url: string } };
export type LeaveRequest = { name?: string };
export type LeaveResponse = { left: string };

/** GET /api/fed/state · POST /api/fed/ingest */
export type FedState = { node: string; messages: FedMessage[]; members: Member[]; peers: PeerView[] };
export type IngestRequest = { messages?: FedMessage[]; from?: { node?: string; url?: string } };
export type IngestResponse = { added: number; node: string };

/** WS /ws/pane/<pane_id> */
export type PaneFrame = { type: "frame"; text: string; revision?: number };
export type PaneError = { type: "error"; error: string };
export type PaneServerMessage = PaneFrame | PaneError;
export type PaneClientMessage =
  | { type: "text"; text: string }
  | { type: "keys"; keys: string[] }
  | { type: "prompt"; text: string };

/** Any endpoint can answer with this instead. */
export type ErrorResponse = { error: string };

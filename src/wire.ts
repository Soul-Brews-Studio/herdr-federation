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
  identity: Identity;
  /** true while peers without a token are still accepted — the UI must say so */
  legacyAllowed: boolean;
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
export type FedState = {
  node: string;
  identity?: Identity;
  messages: FedMessage[];
  members: Member[];
  peers: PeerView[];
  /** who this node federates with, so peers can render the mesh honestly */
  federated?: MemberRecord[];
  /** kicks this node made, published as fact — adopting them is the peer's choice */
  kicks?: AuditEntry[];
};
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

/* ── membership: who this node federates with, and how that was decided ──── */

/** This node's stable identity. The pubkey is what a ban pins to. */
export type Identity = { node: string; pubkey: string; fingerprint: string };

export type InviteStatus = "active" | "expired" | "revoked" | "exhausted";

/**
 * An invite link, Discord-style: the secret lives in the URL, it is spent on
 * redemption, and revoking it stops future joins without touching anyone who
 * already joined through it.
 */
export type InviteLink = {
  id: string;
  /** the secret in the link — present only to the node that issued it */
  token: string | null;
  url: string | null;
  createdAt: string;
  createdBy: string;
  /** null = never expires */
  expiresAt: string | null;
  /** null = unlimited uses */
  maxUses: number | null;
  uses: number;
  note?: string;
  revokedAt?: string;
  usedBy: { node: string; at: string }[];
  status: InviteStatus;
};

/** A node we federate with. Tokens are never part of this view. */
export type MemberRecord = {
  node: string;
  pubkey: string;
  fingerprint: string;
  url?: string;
  joinedAt: string;
  viaInvite?: string;
  lastSeen?: string;
  /** a peer from before tokens existed — allowed only while FED_ALLOW_LEGACY is on */
  legacy?: boolean;
};

export type BanRecord = { node: string; pubkey: string; at: string; by: string; reason?: string };

export type AuditAction =
  | "invite.create"
  | "invite.revoke"
  | "member.join"
  | "member.kick"
  | "member.ban"
  | "member.unban"
  | "redeem.reject"
  | "kick.adopt";

/** One step of a process, as it actually happened — what the admin page draws. */
export type AuditStep = { n: number; label: string; wire?: string; ok: boolean; detail?: string };

export type AuditEntry = {
  id: string;
  at: string;
  action: AuditAction;
  /** the node acted upon */
  node: string;
  /** the node that acted — always the node that wrote the entry */
  by: string;
  reason?: string;
  steps: AuditStep[];
};

/** GET /api/admin */
export type AdminState = {
  node: string;
  identity: Identity;
  /** peers without a token are still accepted; the page must say so loudly */
  legacyAllowed: boolean;
  members: MemberRecord[];
  invites: InviteLink[];
  bans: BanRecord[];
  audit: AuditEntry[];
  /** what the rest of the mesh federates with — read-only, never actionable here */
  meshMembers: Record<string, MemberRecord[]>;
  /** kicks other nodes published and we have not adopted */
  adoptable: (AuditEntry & { from: string })[];
};

/** POST /api/invites */
export type CreateInviteRequest = { hours?: number | null; uses?: number | null; note?: string };
export type CreateInviteResponse = { invite: InviteLink };
export type InvitesResponse = { invites: InviteLink[] };

/** POST /api/peers/redeem — our console telling our own node to go join someone */
export type RedeemRequest = { from?: string; token?: string };
export type RedeemResponse = { joined: { node: string; url: string }; entry: AuditEntry };

/** POST /api/fed/redeem — the joiner presenting an invite to the issuer */
export type FedRedeemRequest = {
  token: string;
  node: string;
  pubkey: string;
  url?: string;
  /** the token WE issue to THEM, so one round trip authenticates both directions */
  offerToken: string;
  at: string;
  sig: string;
};
export type FedRedeemResponse = { node: string; pubkey: string; url?: string; memberToken: string };

/** GET /api/invites/:token — what a join landing page shows before you commit */
export type InvitePreview = {
  node: string;
  fingerprint: string;
  url: string | null;
  expiresAt: string | null;
  createdBy: string;
  note?: string;
  status: InviteStatus;
  members: number;
};

/** POST /api/members/:node/kick · /ban · /unban */
export type KickRequest = { reason?: string };
export type KickResponse = { entry: AuditEntry };
/** GET /api/members · GET /api/audit */
export type MembersResponse = { members: MemberRecord[]; bans: BanRecord[] };
export type AuditResponse = { audit: AuditEntry[] };
/** POST /api/audit/adopt */
export type AdoptRequest = { from?: string; node?: string; reason?: string };

/** Any endpoint can answer with this instead. */
export type ErrorResponse = { error: string };

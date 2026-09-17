/**
 * The console's view of the wire. Everything that crosses the network is
 * defined once in ../../src/wire.ts and imported here, so a rename on the
 * server breaks the build rather than the page.
 */
export type {
  AdminState,
  AuditEntry,
  AuditAction,
  AuditStep,
  BanRecord,
  BroadcastRequest,
  BroadcastResponse,
  BroadcastResult,
  FedEdge,
  CallRecord,
  CallsResponse,
  ErrorResponse,
  FedMessage,
  CreateInviteRequest,
  CreateInviteResponse,
  HeyResponse,
  Identity,
  Invite,
  InviteLink,
  InvitePreview,
  InviteStatus,
  KickResponse,
  MemberRecord,
  MembersResponse,
  RedeemResponse,
  JoinResponse,
  LeaveResponse,
  KnownNode,
  Member,
  PaneClientMessage,
  PaneServerMessage,
  PeerView as Peer,
  RelayedPeer,
  StatusResponse as Status,
  Topology,
  UiTab as Tab,
  UiWorkspace as Workspace,
} from "@wire";

import type { Member } from "@wire";

/**
 * a member plus the node it lives on — the console's own addition.
 * `via` names the hub when we hold no link to that node ourselves: actions
 * route through the hub, and a live pane preview is not possible.
 */
export type Located = Member & { node: string; base: string; via?: string };

export type Squad = { id: string; name: string; members: Located[]; /** 0 = fluid */ cols?: number };

/**
 * The console's view of the wire. Everything that crosses the network is
 * defined once in ../../src/wire.ts and imported here, so a rename on the
 * server breaks the build rather than the page.
 */
export type {
  BroadcastRequest,
  BroadcastResponse,
  BroadcastResult,
  CallRecord,
  CallsResponse,
  ErrorResponse,
  FedMessage,
  HeyResponse,
  Invite,
  JoinResponse,
  LeaveResponse,
  KnownNode,
  Member,
  PaneClientMessage,
  PaneServerMessage,
  PeerView as Peer,
  StatusResponse as Status,
  Topology,
  UiTab as Tab,
  UiWorkspace as Workspace,
} from "@wire";

import type { Member } from "@wire";

/** a member plus the node it lives on — the console's own addition */
export type Located = Member & { node: string; base: string };

export type Squad = { id: string; name: string; members: Located[]; /** 0 = fluid */ cols?: number };

import type {
  AdminState, BroadcastRequest, BroadcastResponse, CallsResponse, CreateInviteRequest,
  CreateInviteResponse, ErrorResponse, HeyResponse, InvitePreview, JoinResponse, KickResponse,
  LeaveResponse, RedeemResponse, Status,
} from "./types";

/**
 * One place that talks to a node. Every endpoint names its response type, so a
 * component never restates a shape inline — and an `{error}` reply becomes a
 * thrown Error rather than a field each caller has to remember to check.
 */
async function call<T>(path: string, init?: RequestInit, base = ""): Promise<T> {
  const res = await fetch(`${base}${path}`, {
    ...init,
    headers: init?.body ? { "content-type": "application/json", ...init.headers } : init?.headers,
  });
  const body = (await res.json()) as T | ErrorResponse;
  if (body && typeof body === "object" && "error" in body) throw new Error((body as ErrorResponse).error);
  if (!res.ok) throw new Error(`${res.status} ${res.statusText}`);
  return body as T;
}

const post = <T>(path: string, payload: unknown, base = "") =>
  call<T>(path, { method: "POST", body: JSON.stringify(payload) }, base);

export const api = {
  status: () => call<Status>("/api/status"),
  calls: (limit = 60) => call<CallsResponse>(`/api/calls?limit=${limit}`),
  /** `to` is a pane id or "*" for the federation; `base` targets another node */
  hey: (to: string, text: string, base = "") => post<HeyResponse>("/api/hey", { to, text }, base),
  broadcast: (body: BroadcastRequest) => post<BroadcastResponse>("/api/broadcast", body),
  join: (url: string) => post<JoinResponse>("/api/peers/join", { url }),
  leave: (name: string) => post<LeaveResponse>("/api/peers/leave", { name }),

  /* ── membership ─────────────────────────────────────────────────────── */
  admin: () => call<AdminState>("/api/admin"),
  createInvite: (body: CreateInviteRequest) => post<CreateInviteResponse>("/api/invites", body),
  revokeInvite: (id: string) => call<CreateInviteResponse>(`/api/invites/${encodeURIComponent(id)}`, { method: "DELETE" }),
  /** read an invite at the node that issued it — `base` is that node, not ours */
  previewInvite: (base: string, token: string) => call<InvitePreview>(`/api/invite-preview/${encodeURIComponent(token)}`, undefined, base),
  /** tell OUR node to go redeem an invite at theirs */
  redeem: (from: string, token: string) => post<RedeemResponse>("/api/peers/redeem", { from, token }),
  kick: (node: string, reason?: string) => post<KickResponse>(`/api/members/${encodeURIComponent(node)}/kick`, { reason }),
  ban: (node: string, reason?: string) => post<KickResponse>(`/api/members/${encodeURIComponent(node)}/ban`, { reason }),
  unban: (node: string) => post<KickResponse>(`/api/members/${encodeURIComponent(node)}/unban`, {}),
  adoptKick: (node: string, from: string, reason?: string) => post<KickResponse>("/api/audit/adopt", { node, from, reason }),
};

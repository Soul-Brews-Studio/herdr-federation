import type {
  BroadcastRequest, BroadcastResponse, CallsResponse, ErrorResponse, HeyResponse,
  JoinResponse, LeaveResponse, Status,
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
};

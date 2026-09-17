/**
 * Membership: invites, members, bans, and the audit log that records how each
 * one came to be.
 *
 * The model is Discord's, adapted to a mesh with no server above the nodes:
 *
 *   invite   a secret in a link. Spent on redemption. Revoking it stops future
 *            joins and touches nobody who already joined through it.
 *   member   what persists after an invite is spent. Carries the pair of tokens
 *            the relationship rides on, and the pubkey proven at redemption.
 *   kick     delete the member. Their token dies, so their next request is 401.
 *            They can come back through any invite that is still valid.
 *   ban      pin the pubkey. No invite will let that key back in.
 *
 * Enforcement is LOCAL ONLY, and that is not a shortcut — it is the only honest
 * answer for a peer-to-peer mesh. Each node holds its own door, the way each
 * Matrix homeserver holds its own ACL. A kick is published so peers can see it
 * and adopt it in one click; nothing makes them.
 */

import { secret, verify, fingerprint } from "./identity";
import type {
  AdoptRequest, AuditAction, AuditEntry, AuditStep, BanRecord, CreateInviteRequest,
  FedRedeemRequest, InviteLink, InviteStatus, MemberRecord,
} from "./wire";

/** An invite as it lives on disk — the view handed to the UI redacts nothing here, since only the issuer holds it. */
type StoredInvite = Omit<InviteLink, "status" | "url">;

/** A member as it lives on disk. The two tokens never leave this file. */
type StoredMember = MemberRecord & {
  /** we issued this to them; they present it to us; authenticating means matching it */
  ourToken?: string;
  /** they issued this to us; we present it on every outbound call to them */
  theirToken?: string;
};

export type RedeemFailure = "unknown_invite" | "revoked" | "expired" | "exhausted" | "banned" | "bad_signature" | "stale_request" | "self";

export class RedeemError extends Error {
  constructor(readonly code: RedeemFailure, message?: string) {
    super(message ?? code);
  }
}

/** A redemption request older than this is refused, so a captured one cannot be replayed later. */
const SIGNATURE_WINDOW_MS = 5 * 60 * 1000;
const AUDIT_CAP = 500;

const id = () => Math.random().toString(36).slice(2, 10);

export class Members {
  #invites: StoredInvite[] = [];
  #members: StoredMember[] = [];
  #bans: BanRecord[] = [];
  #audit: AuditEntry[] = [];

  constructor(
    readonly node: string,
    readonly statePath: string,
    /** how peers reach us, when we know — stamped into invite links */
    readonly baseUrl: () => string | null,
    /** peers with no token at all: tolerated during the upgrade, never silently */
    readonly allowLegacy: boolean,
  ) {}

  async load() {
    try {
      const saved = await Bun.file(this.statePath).json();
      this.#invites = saved.invites ?? [];
      this.#members = saved.members ?? [];
      this.#bans = saved.bans ?? [];
      this.#audit = saved.audit ?? [];
    } catch {
      // first run
    }
  }

  async save() {
    await Bun.write(
      this.statePath,
      JSON.stringify({ invites: this.#invites, members: this.#members, bans: this.#bans, audit: this.#audit.slice(-AUDIT_CAP) }, null, 2),
    );
  }

  /* ── audit ──────────────────────────────────────────────────────────── */

  /** Record what happened, step by step, so the admin page can replay it rather than describe it. */
  record(action: AuditAction, node: string, steps: AuditStep[], reason?: string, summary?: string): AuditEntry {
    const entry: AuditEntry = { id: id(), at: new Date().toISOString(), action, node, by: this.node, reason, summary, steps };
    this.#audit.push(entry);
    this.#audit = this.#audit.slice(-AUDIT_CAP);
    void this.save();
    return entry;
  }

  get audit() {
    return [...this.#audit].reverse();
  }

  /** The kicks this node made, published so peers can decide for themselves. */
  get publishedKicks() {
    return this.#audit.filter((e) => e.action === "member.kick" || e.action === "member.ban").slice(-50);
  }

  /* ── invites ────────────────────────────────────────────────────────── */

  #status(inv: StoredInvite): InviteStatus {
    if (inv.revokedAt) return "revoked";
    if (inv.expiresAt && Date.parse(inv.expiresAt) < Date.now()) return "expired";
    if (inv.maxUses !== null && inv.uses >= inv.maxUses) return "exhausted";
    return "active";
  }

  #link(inv: StoredInvite): InviteLink {
    const base = this.baseUrl();
    return { ...inv, status: this.#status(inv), url: base ? `${base}/join/${inv.token}` : null };
  }

  get invites(): InviteLink[] {
    return this.#invites.map((i) => this.#link(i)).reverse();
  }

  /** Default is Discord's: a day, unlimited uses, revocable. */
  createInvite({ hours = 24, uses = null, note }: CreateInviteRequest): InviteLink {
    const inv: StoredInvite = {
      id: id(),
      token: secret(),
      createdAt: new Date().toISOString(),
      createdBy: this.node,
      expiresAt: hours === null ? null : new Date(Date.now() + hours * 3600_000).toISOString(),
      maxUses: uses ?? null,
      uses: 0,
      note,
      usedBy: [],
    };
    this.#invites.push(inv);
    const link = this.#link(inv);
    this.record("invite.create", this.node, [
      { n: 1, label: "mint a secret", ok: true, detail: `24 bytes, base64url · id ${inv.id}` },
      { n: 2, label: "set the terms", ok: true, detail: `${inv.expiresAt ? `expires ${inv.expiresAt}` : "never expires"} · ${inv.maxUses ?? "unlimited"} uses` },
      { n: 3, label: "hand out the link", wire: link.url ?? "(this node is not reachable — no link)", ok: !!link.url },
    ], undefined, `invite ${inv.id} · ${inv.expiresAt ? `${hours}h` : "no expiry"} · ${inv.maxUses ?? "∞"} uses`);
    return link;
  }

  revokeInvite(inviteId: string): InviteLink | undefined {
    const inv = this.#invites.find((i) => i.id === inviteId);
    if (!inv || inv.revokedAt) return undefined;
    inv.revokedAt = new Date().toISOString();
    this.record("invite.revoke", this.node, [
      { n: 1, label: "mark the invite dead", ok: true, detail: `id ${inv.id} · used ${inv.uses}×` },
      { n: 2, label: "members who already joined keep their membership", ok: true, detail: inv.usedBy.map((u) => u.node).join(", ") || "nobody used it" },
    ], undefined, `invite ${inv.id} · used ${inv.uses}×`);
    return this.#link(inv);
  }

  /** What a landing page may show about a link before anyone commits to it. */
  preview(token: string) {
    const inv = this.#invites.find((i) => i.token === token);
    if (!inv) return undefined;
    return { invite: this.#link(inv), status: this.#status(inv) };
  }

  /* ── members ────────────────────────────────────────────────────────── */

  get members(): MemberRecord[] {
    return this.#members.map(({ ourToken: _o, theirToken: _t, ...view }) => view);
  }

  get bans() {
    return [...this.#bans].reverse();
  }

  /** The token to present when calling this peer. */
  tokenFor(node: string) {
    return this.#members.find((m) => m.node === node)?.theirToken;
  }

  /** Who is this request from? Matching the token IS the authentication. */
  authenticate(token: string | null): MemberRecord | undefined {
    if (!token) return undefined;
    const hit = this.#members.find((m) => m.ourToken && m.ourToken === token);
    if (!hit) return undefined;
    hit.lastSeen = new Date().toISOString();
    return hit;
  }

  isBanned(pubkey: string, node: string) {
    return this.#bans.some((b) => b.pubkey === pubkey || b.node === node);
  }

  /**
   * Somebody presents an invite. This is the only place a new relationship is
   * born, and the only place a signature is checked.
   */
  redeem(req: FedRedeemRequest): { memberToken: string; entry: AuditEntry } {
    const steps: AuditStep[] = [];
    const fail = (code: RedeemFailure, label: string, detail: string): never => {
      steps.push({ n: steps.length + 1, label, ok: false, detail });
      this.record("redeem.reject", req.node ?? "unknown", steps, code, detail);
      throw new RedeemError(code, detail);
    };

    if (req.node === this.node) fail("self", "check the joiner is not us", "that invite belongs to this node");

    const inv = this.#invites.find((i) => i.token === req.token);
    if (!inv) fail("unknown_invite", "look the invite up", "no invite with that secret");
    steps.push({ n: 1, label: "look the invite up", ok: true, detail: `id ${inv!.id}, created ${inv!.createdAt}` });

    const status = this.#status(inv!);
    if (status !== "active") fail(status as RedeemFailure, "check the invite is still good", `invite is ${status}`);
    steps.push({ n: 2, label: "check the invite is still good", ok: true, detail: `${inv!.expiresAt ? `expires ${inv!.expiresAt}` : "no expiry"} · used ${inv!.uses}/${inv!.maxUses ?? "∞"}` });

    if (this.isBanned(req.pubkey, req.node)) fail("banned", "check the key is not banned", `${req.node} is banned on this node`);
    steps.push({ n: 3, label: "check the key is not banned", ok: true, detail: fingerprint(req.pubkey) });

    const age = Math.abs(Date.now() - Date.parse(req.at));
    if (!Number.isFinite(age) || age > SIGNATURE_WINDOW_MS)
      fail("stale_request", "check the request is fresh", `signed ${Math.round(age / 1000)}s ago — window is ${SIGNATURE_WINDOW_MS / 1000}s`);

    const message = redeemMessage(req);
    if (!verify(message, req.sig, req.pubkey)) fail("bad_signature", "verify the signature", "signature does not match the offered key");
    steps.push({ n: 4, label: "verify the signature", ok: true, detail: `ed25519 over "${message}"` });

    const ourToken = secret();
    inv!.uses++;
    inv!.usedBy.push({ node: req.node, at: new Date().toISOString() });
    this.#upsert({
      node: req.node,
      pubkey: req.pubkey,
      fingerprint: fingerprint(req.pubkey),
      url: req.url,
      joinedAt: new Date().toISOString(),
      viaInvite: inv!.id,
      ourToken,
      theirToken: req.offerToken,
    });
    steps.push({ n: 5, label: "issue a member token and store the membership", ok: true, detail: `invite ${inv!.id} now used ${inv!.uses}/${inv!.maxUses ?? "∞"}` });

    const entry = this.record("member.join", req.node, steps, undefined, `invite ${inv!.id} · key ${fingerprint(req.pubkey)}`);
    return { memberToken: ourToken, entry };
  }

  /**
   * The other half: we redeemed somewhere, and now record who we joined.
   *
   * `summary` comes from the caller because the distinguishing fact on this side
   * is which invite we spent — and that invite belongs to the other node, so it
   * has no id we can read. Two joins to the same peer are otherwise identical.
   */
  adopt(peer: { node: string; pubkey: string; url?: string; ourToken: string; theirToken: string }, steps: AuditStep[], summary?: string) {
    this.#upsert({
      node: peer.node,
      pubkey: peer.pubkey,
      fingerprint: fingerprint(peer.pubkey),
      url: peer.url,
      joinedAt: new Date().toISOString(),
      ourToken: peer.ourToken,
      theirToken: peer.theirToken,
    });
    return this.record("member.join", peer.node, steps, undefined, summary ?? `we joined them · key ${fingerprint(peer.pubkey)}`);
  }

  /**
   * A peer carried over from before tokens existed. Recorded as a member so the
   * admin page can show it, flagged so the page can say it is not verified.
   */
  adoptLegacy(node: string, url?: string) {
    if (this.#members.some((m) => m.node === node)) return;
    this.#upsert({ node, pubkey: "", fingerprint: "", url, joinedAt: new Date().toISOString(), legacy: true });
  }

  #upsert(member: StoredMember) {
    const at = this.#members.findIndex((m) => m.node === member.node);
    if (at >= 0) {
      const merged = { ...this.#members[at], ...member };
      // a real handshake retires the legacy flag: the record now has a proven key
      if (member.pubkey) delete merged.legacy;
      this.#members[at] = merged;
    } else this.#members.push(member);
    void this.save();
  }

  /**
   * Kick: the membership stops existing here. Their token dies with it, which
   * is the whole difference from the old `leave()` — that only stopped US
   * calling THEM, and left their door into us wide open.
   */
  kick(node: string, reason?: string, adopted?: string): AuditEntry | undefined {
    const member = this.#members.find((m) => m.node === node);
    if (!member) return undefined;
    this.#members = this.#members.filter((m) => m.node !== node);
    void this.save();
    return this.record(adopted ? "kick.adopt" : "member.kick", node, [
      { n: 1, label: "delete the membership", ok: true, detail: `joined ${member.joinedAt}${member.viaInvite ? ` via invite ${member.viaInvite}` : ""}` },
      { n: 2, label: "their token stops authenticating", ok: true, detail: "next /api/fed/* call from them answers 401" },
      { n: 3, label: "stop pushing and pulling with them", ok: true, detail: `${node} removed from peers.json` },
      { n: 4, label: "publish the kick", ok: true, detail: adopted ? `adopted from ${adopted}` : "peers may adopt it; nothing makes them" },
    ], reason, adopted ? `adopted from ${adopted}` : reason || (member.viaInvite ? `had joined via invite ${member.viaInvite}` : "no reason given"));
  }

  /** Ban: the same as a kick, plus the pubkey is pinned so no invite lets it back. */
  ban(node: string, reason?: string): AuditEntry {
    const member = this.#members.find((m) => m.node === node);
    const pubkey = member?.pubkey ?? "";
    this.kick(node, reason);
    this.#bans.push({ node, pubkey, at: new Date().toISOString(), by: this.node, reason });
    void this.save();
    return this.record("member.ban", node, [
      { n: 1, label: "pin the key", ok: true, detail: pubkey ? `${fingerprint(pubkey)} — every future redeem from this key is refused` : "no key on record (legacy peer) — the node NAME is pinned instead" },
      { n: 2, label: "a valid invite no longer helps them", ok: true, detail: "this is the only difference from a kick" },
    ], reason, pubkey ? `key ${fingerprint(pubkey)} pinned` : "node name pinned (no key on record)");
  }

  unban(node: string): AuditEntry | undefined {
    const ban = this.#bans.find((b) => b.node === node);
    if (!ban) return undefined;
    this.#bans = this.#bans.filter((b) => b.node !== node);
    void this.save();
    return this.record("member.unban", node, [
      { n: 1, label: "unpin the key", ok: true, detail: ban.pubkey ? fingerprint(ban.pubkey) : node },
      { n: 2, label: "they still need a valid invite to return", ok: true, detail: "unban is not an invite" },
    ], undefined, ban.pubkey ? `key ${fingerprint(ban.pubkey)} unpinned` : `${node} unpinned`);
  }

  adoptKick({ node, from, reason }: AdoptRequest & { node: string; from: string }) {
    return this.kick(node, reason ?? `adopted from ${from}`, from);
  }
}

/** The exact string a joiner signs. Both ends must build it identically. */
export const redeemMessage = (req: Pick<FedRedeemRequest, "token" | "node" | "at">) =>
  `herdr-federation:redeem:${req.token}:${req.node}:${req.at}`;

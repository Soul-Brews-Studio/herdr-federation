// Members.swift — src/members.ts, line for line.
//
// Membership: invites, members, bans, and the audit log that records how each
// one came to be. The model is Discord's, adapted to a mesh with no server
// above the nodes:
//
//   invite   a secret in a link. Spent on redemption. Revoking it stops future
//            joins and touches nobody who already joined through it.
//   member   what persists after an invite is spent. Carries the pair of tokens
//            the relationship rides on, and the pubkey proven at redemption.
//   kick     delete the member. Their token dies, so their next request is 401.
//   ban      pin the pubkey. No invite will let that key back in.
//
// Enforcement is LOCAL ONLY. A kick is published so peers can see it and adopt
// it in one click; nothing makes them.
//
// Every step label, `wire` and `detail` string below is part of the contract —
// the admin page renders them verbatim and the conformance harness diffs them.
// Where the Bun original is odd, the oddity is reproduced, not repaired.
//
// The two tokens on a StoredMember never leave this file: no public method
// returns them except `tokenFor()`, and nothing here logs them.

import Foundation

/// An invite as it lives on disk — `Omit<InviteLink, "status" | "url">`.
/// Declared in the Bun object-literal order so the file reads the same.
/// `expiresAt` and `maxUses` are written as an explicit `null`; `note` and
/// `revokedAt` are omitted while absent, exactly as `JSON.stringify` does.
private struct StoredInvite: Codable, Sendable {
    var id: String
    @NullIfNil var token: String?
    var createdAt: String
    var createdBy: String
    @NullIfNil var expiresAt: String?
    @NullIfNil var maxUses: Int?
    var uses: Int
    var note: String?
    var usedBy: [InviteUse]
    var revokedAt: String?

    init(id: String, token: String?, createdAt: String, createdBy: String, expiresAt: String?, maxUses: Int?, uses: Int, note: String?, usedBy: [InviteUse], revokedAt: String?) {
        self.id = id; self.token = token; self.createdAt = createdAt; self.createdBy = createdBy
        self.expiresAt = expiresAt; self.maxUses = maxUses; self.uses = uses; self.note = note
        self.usedBy = usedBy; self.revokedAt = revokedAt
    }

    enum CodingKeys: String, CodingKey {
        case id, token, createdAt, createdBy, expiresAt, maxUses, uses, note, usedBy, revokedAt
    }

    /// JS reads whatever is in the file without validating it, so absence of a
    /// countable field is tolerated the way `inv.uses` being `undefined` is.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? ""
        token = try c.decode(NullIfNil<String>.self, forKey: .token).wrappedValue
        createdAt = try c.decodeIfPresent(String.self, forKey: .createdAt) ?? ""
        createdBy = try c.decodeIfPresent(String.self, forKey: .createdBy) ?? ""
        expiresAt = try c.decode(NullIfNil<String>.self, forKey: .expiresAt).wrappedValue
        maxUses = try c.decode(NullIfNil<Int>.self, forKey: .maxUses).wrappedValue
        uses = try c.decodeIfPresent(Int.self, forKey: .uses) ?? 0
        note = try c.decodeIfPresent(String.self, forKey: .note)
        usedBy = try c.decodeIfPresent([InviteUse].self, forKey: .usedBy) ?? []
        revokedAt = try c.decodeIfPresent(String.self, forKey: .revokedAt)
    }
}

/// A member as it lives on disk: `MemberRecord & { ourToken?, theirToken? }`.
/// The two tokens never leave this file.
private struct StoredMember: Codable, Sendable {
    var node: String
    var pubkey: String
    var fingerprint: String
    var url: String?
    var joinedAt: String
    var viaInvite: String?
    var lastSeen: String?
    var legacy: Bool?
    /// we issued this to them; they present it to us; authenticating means matching it
    var ourToken: String?
    /// they issued this to us; we present it on every outbound call to them
    var theirToken: String?

    init(node: String, pubkey: String, fingerprint: String, url: String?, joinedAt: String, viaInvite: String? = nil, lastSeen: String? = nil, legacy: Bool? = nil, ourToken: String? = nil, theirToken: String? = nil) {
        self.node = node; self.pubkey = pubkey; self.fingerprint = fingerprint; self.url = url
        self.joinedAt = joinedAt; self.viaInvite = viaInvite; self.lastSeen = lastSeen
        self.legacy = legacy; self.ourToken = ourToken; self.theirToken = theirToken
    }

    enum CodingKeys: String, CodingKey {
        case node, pubkey, fingerprint, url, joinedAt, viaInvite, lastSeen, legacy, ourToken, theirToken
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        node = try c.decodeIfPresent(String.self, forKey: .node) ?? ""
        pubkey = try c.decodeIfPresent(String.self, forKey: .pubkey) ?? ""
        fingerprint = try c.decodeIfPresent(String.self, forKey: .fingerprint) ?? ""
        url = try c.decodeIfPresent(String.self, forKey: .url)
        joinedAt = try c.decodeIfPresent(String.self, forKey: .joinedAt) ?? ""
        viaInvite = try c.decodeIfPresent(String.self, forKey: .viaInvite)
        lastSeen = try c.decodeIfPresent(String.self, forKey: .lastSeen)
        legacy = try c.decodeIfPresent(Bool.self, forKey: .legacy)
        ourToken = try c.decodeIfPresent(String.self, forKey: .ourToken)
        theirToken = try c.decodeIfPresent(String.self, forKey: .theirToken)
    }

    /// `({ ourToken: _o, theirToken: _t, ...view }) => view`
    var view: MemberRecord {
        MemberRecord(node: node, pubkey: pubkey, fingerprint: fingerprint, url: url, joinedAt: joinedAt, viaInvite: viaInvite, lastSeen: lastSeen, legacy: legacy)
    }
}

/// `.fed-members.json` — `{ invites, members, bans, audit }`, pretty-printed.
private struct Persisted: Codable, Sendable {
    var invites: [StoredInvite]
    var members: [StoredMember]
    var bans: [BanRecord]
    var audit: [AuditEntry]

    init(invites: [StoredInvite], members: [StoredMember], bans: [BanRecord], audit: [AuditEntry]) {
        self.invites = invites; self.members = members; self.bans = bans; self.audit = audit
    }

    enum CodingKeys: String, CodingKey { case invites, members, bans, audit }

    /// `saved.invites ?? []` — per key, so one unreadable array does not cost
    /// the other three (JS would have kept the garbage; we keep the rest).
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        invites = ((try? c.decodeIfPresent([StoredInvite].self, forKey: .invites)) ?? nil) ?? []
        members = ((try? c.decodeIfPresent([StoredMember].self, forKey: .members)) ?? nil) ?? []
        bans = ((try? c.decodeIfPresent([BanRecord].self, forKey: .bans)) ?? nil) ?? []
        audit = ((try? c.decodeIfPresent([AuditEntry].self, forKey: .audit)) ?? nil) ?? []
    }
}

/// One `#upsert` argument, with JS spread semantics: a key can be ABSENT (keep
/// what is stored), present-but-undefined (`.null` — overwrite with nothing,
/// which is how `adopt()` with no url clears a stored one), or present with a
/// value. `{ ...stored, ...incoming }` copies undefined keys too, and that
/// detail is load-bearing here.
private struct MemberPatch: Sendable {
    var node: String
    var pubkey: Nullable<String> = .absent
    var fingerprint: Nullable<String> = .absent
    var url: Nullable<String> = .absent
    var joinedAt: Nullable<String> = .absent
    var viaInvite: Nullable<String> = .absent
    var lastSeen: Nullable<String> = .absent
    var legacy: Nullable<Bool> = .absent
    var ourToken: Nullable<String> = .absent
    var theirToken: Nullable<String> = .absent
}

/// `x` in `x ? a : b` for a string — JS treats `""` as false, and several
/// branches here depend on that (`reason || …`, `!!link.url`, `adopted ? …`).
private func truthy(_ s: String?) -> Bool { !(s ?? "").isEmpty }

public actor Members: MembersStore {
    public nonisolated let node: String
    public nonisolated let statePath: String
    /// how peers reach us, when we know — stamped into invite links
    private let baseUrl: @Sendable () -> String?
    /// peers with no token at all: tolerated during the upgrade, never silently
    public nonisolated let allowLegacy: Bool

    private var storedInvites: [StoredInvite] = []
    private var storedMembers: [StoredMember] = []
    private var storedBans: [BanRecord] = []
    private var auditLog: [AuditEntry] = []

    public init(node: String, statePath: String, baseUrl: @escaping @Sendable () -> String?, allowLegacy: Bool) {
        self.node = node
        self.statePath = statePath
        self.baseUrl = baseUrl
        self.allowLegacy = allowLegacy
    }

    // MARK: - disk

    public func load() async {
        guard let data = FileManager.default.contents(atPath: statePath),
              let saved = try? JSONCoding.decode(Persisted.self, from: data)
        else { return }   // first run
        storedInvites = saved.invites
        storedMembers = saved.members
        storedBans = saved.bans
        auditLog = saved.audit
    }

    public func save() async {
        let snapshot = Persisted(
            invites: storedInvites,
            members: storedMembers,
            bans: storedBans,
            audit: Array(auditLog.suffix(Const.auditCap))
        )
        guard let data = try? JSONCoding.encode(snapshot, pretty: true) else { return }
        try? data.write(to: URL(fileURLWithPath: statePath))
    }

    // MARK: - audit

    /// Record what happened, step by step, so the admin page can replay it
    /// rather than describe it.
    @discardableResult
    public func record(_ action: AuditAction, node: String, steps: [AuditStep], reason: String? = nil, summary: String? = nil) async -> AuditEntry {
        let entry = AuditEntry(id: randomId(), at: Stamp.iso(), action: action, node: node, by: self.node, reason: reason, summary: summary, steps: steps)
        auditLog.append(entry)
        auditLog = Array(auditLog.suffix(Const.auditCap))
        await save()
        return entry
    }

    /// newest first
    public func audit() async -> [AuditEntry] { Array(auditLog.reversed()) }

    /// The kicks this node made, published so peers can decide for themselves.
    /// Oldest first, the last 50.
    public func publishedKicks() async -> [AuditEntry] {
        Array(auditLog.filter { $0.action == .memberKick || $0.action == .memberBan }.suffix(Const.publishedKicksCap))
    }

    // MARK: - invites

    private func status(_ inv: StoredInvite) -> InviteStatus {
        if truthy(inv.revokedAt) { return .revoked }
        // an unparseable expiresAt is NaN in JS, and `NaN < now` is false
        if truthy(inv.expiresAt), let e = inv.expiresAt, let at = Stamp.parse(e),
           at.timeIntervalSince1970 * 1000 < Double(Stamp.nowMs()) { return .expired }
        // `maxUses !== null` — a MISSING maxUses compares against undefined and
        // never exhausts either, so nil covers both cases identically
        if let max = inv.maxUses, inv.uses >= max { return .exhausted }
        return .active
    }

    private func link(_ inv: StoredInvite) -> InviteLink {
        let base = baseUrl()
        let url = truthy(base) ? "\(base!)/join/\(inv.token ?? "null")" : nil
        return InviteLink(
            id: inv.id, token: inv.token, url: url,
            createdAt: inv.createdAt, createdBy: inv.createdBy,
            expiresAt: inv.expiresAt, maxUses: inv.maxUses, uses: inv.uses,
            note: inv.note, revokedAt: inv.revokedAt, usedBy: inv.usedBy,
            status: status(inv)
        )
    }

    /// newest first, each with `status` and `url` computed
    public func invites() async -> [InviteLink] {
        Array(storedInvites.map { link($0) }.reversed())
    }

    /// Default is Discord's: a day, unlimited uses, revocable.
    public func createInvite(_ req: CreateInviteRequest) async -> InviteLink {
        // `{ hours = 24, uses = null }`: the default applies to ABSENT only,
        // an explicit null means "never expires".
        // Double, not Int: members.ts multiplies whatever arrived by 3600_000,
        // so `{"hours":0.5}` is a 30-minute invite on the fleet and an Int would
        // have refused the body and silently issued a 24-hour one.
        let hours: Double?
        switch req.hours {
        case .absent: hours = Double(Const.inviteDefaultHours)
        case .null: hours = nil
        case .value(let h): hours = h
        }
        // `uses ?? null` — absent and null are both unlimited. A non-finite
        // `uses` is stored as NaN by Bun, and `uses >= NaN` is false forever,
        // i.e. unlimited; nil says the same thing without trapping on Int(NaN).
        let maxUses: Int? = req.uses.value.flatMap { $0.isFinite ? Int($0) : nil }

        // Double, not Int64: JS would throw RangeError past ±8.64e15 ms rather
        // than trap, and a trap is the worse of the two failures. The route has
        // already refused a body whose instant is not representable.
        let expiresAt = hours.map { Stamp.iso(Date(timeIntervalSince1970: (Double(Stamp.nowMs()) + $0 * 3_600_000) / 1000)) }

        let inv = StoredInvite(
            id: randomId(), token: secret(), createdAt: Stamp.iso(), createdBy: node,
            expiresAt: expiresAt, maxUses: maxUses, uses: 0, note: req.note, usedBy: [], revokedAt: nil
        )
        storedInvites.append(inv)
        let l = link(inv)
        await record(.inviteCreate, node: node, steps: [
            AuditStep(n: 1, label: "mint a secret", ok: true, detail: "24 bytes, base64url · id \(inv.id)"),
            AuditStep(n: 2, label: "set the terms", ok: true, detail: "\(truthy(inv.expiresAt) ? "expires \(inv.expiresAt!)" : "never expires") · \(inv.maxUses.map(String.init) ?? "unlimited") uses"),
            AuditStep(n: 3, label: "hand out the link", wire: truthy(l.url) ? l.url! : "(this node is not reachable — no link)", ok: truthy(l.url)),
        ], reason: nil, summary: "invite \(inv.id) · \(truthy(inv.expiresAt) ? "\(hours.map(jsNumberText) ?? "null")h" : "no expiry") · \(inv.maxUses.map(String.init) ?? "∞") uses")
        return l
    }

    /// nil when unknown or already revoked
    public func revokeInvite(_ inviteId: String) async -> InviteLink? {
        guard let at = storedInvites.firstIndex(where: { $0.id == inviteId }), !truthy(storedInvites[at].revokedAt) else { return nil }
        storedInvites[at].revokedAt = Stamp.iso()
        let inv = storedInvites[at]
        let joined = inv.usedBy.map { $0.node }.joined(separator: ", ")
        await record(.inviteRevoke, node: node, steps: [
            AuditStep(n: 1, label: "mark the invite dead", ok: true, detail: "id \(inv.id) · used \(inv.uses)×"),
            AuditStep(n: 2, label: "members who already joined keep their membership", ok: true, detail: truthy(joined) ? joined : "nobody used it"),
        ], reason: nil, summary: "invite \(inv.id) · used \(inv.uses)×")
        return link(inv)
    }

    /// What a landing page may show about a link before anyone commits to it.
    public func preview(token: String) async -> (invite: InviteLink, status: InviteStatus)? {
        guard let inv = storedInvites.first(where: { $0.token == token }) else { return nil }
        return (invite: link(inv), status: status(inv))
    }

    // MARK: - members

    /// tokens stripped
    public func members() async -> [MemberRecord] { storedMembers.map { $0.view } }

    /// newest first
    public func bans() async -> [BanRecord] { Array(storedBans.reversed()) }

    /// The token to present when calling this peer.
    public func tokenFor(_ node: String) async -> String? {
        storedMembers.first(where: { $0.node == node })?.theirToken
    }

    /// Who is this request from? Matching the token IS the authentication.
    public func authenticate(token: String?) async -> MemberRecord? {
        guard truthy(token), let token else { return nil }
        guard let at = storedMembers.firstIndex(where: { truthy($0.ourToken) && $0.ourToken == token }) else { return nil }
        // members.ts stamps lastSeen and does NOT save — the stamp survives only
        // until the next save() from some other path. Ported as-is.
        storedMembers[at].lastSeen = Stamp.iso()
        return storedMembers[at].view
    }

    public func isBanned(pubkey: String, node: String) async -> Bool {
        storedBans.contains { $0.pubkey == pubkey || $0.node == node }
    }

    /// Somebody presents an invite. This is the only place a new relationship is
    /// born, and the only place a signature is checked.
    public func redeem(_ req: FedRedeemRequest) async throws -> (memberToken: String, entry: AuditEntry) {
        // members.ts:201 records every rejection under `req.node ?? "unknown"`,
        // so a body with NO `node` key reads "unknown" in the audit log while an
        // explicit "" stays "".
        let auditNode = req.auditNode
        var steps: [AuditStep] = []

        if req.node == node {
            throw await fail(.self, "check the joiner is not us", "that invite belongs to this node", from: auditNode, steps: &steps)
        }

        guard let at = storedInvites.firstIndex(where: { $0.token == req.token }) else {
            throw await fail(.unknownInvite, "look the invite up", "no invite with that secret", from: auditNode, steps: &steps)
        }
        steps.append(AuditStep(n: 1, label: "look the invite up", ok: true, detail: "id \(storedInvites[at].id), created \(storedInvites[at].createdAt)"))

        let st = status(storedInvites[at])
        if st != .active {
            let code: RedeemFailure
            switch st {
            case .revoked: code = .revoked
            case .expired: code = .expired
            case .exhausted: code = .exhausted
            case .active: code = .unknownInvite   // unreachable
            }
            throw await fail(code, "check the invite is still good", "invite is \(st.rawValue)", from: auditNode, steps: &steps)
        }
        steps.append(AuditStep(n: 2, label: "check the invite is still good", ok: true, detail: "\(truthy(storedInvites[at].expiresAt) ? "expires \(storedInvites[at].expiresAt!)" : "no expiry") · used \(storedInvites[at].uses)/\(storedInvites[at].maxUses.map(String.init) ?? "∞")"))

        if await isBanned(pubkey: req.pubkey, node: req.node) {
            throw await fail(.banned, "check the key is not banned", "\(req.node) is banned on this node", from: auditNode, steps: &steps)
        }
        steps.append(AuditStep(n: 3, label: "check the key is not banned", ok: true, detail: fingerprint(req.pubkey)))

        // `Math.abs(Date.now() - Date.parse(req.at))` — an unparseable `at` is
        // NaN, `!Number.isFinite(NaN)` fails the check, and the detail then
        // literally reads "signed NaNs ago". Kept.
        let age: Double = Stamp.parse(req.at).map { abs(Double(Stamp.nowMs()) - $0.timeIntervalSince1970 * 1000) } ?? Double.nan
        if !age.isFinite || age > Double(Const.signatureWindowMs) {
            let secs = age.isFinite ? String(Int((age / 1000).rounded())) : "NaN"
            throw await fail(.staleRequest, "check the request is fresh", "signed \(secs)s ago — window is \(Const.signatureWindowMs / 1000)s", from: auditNode, steps: &steps)
        }
        // NB: no step is pushed for a fresh request — members.ts records only
        // the failure, so the successful path jumps from n:3 to n:4.

        let message = redeemMessage(token: req.token, node: req.node, at: req.at)
        if !verifySignature(message: message, signature: req.sig, pubkeyHex: req.pubkey) {
            throw await fail(.badSignature, "verify the signature", "signature does not match the offered key", from: auditNode, steps: &steps)
        }
        steps.append(AuditStep(n: 4, label: "verify the signature", ok: true, detail: "ed25519 over \"\(message)\""))

        let ourToken = secret()
        storedInvites[at].uses += 1
        storedInvites[at].usedBy.append(InviteUse(node: req.node, at: Stamp.iso()))
        let inviteId = storedInvites[at].id
        await upsert(MemberPatch(
            node: req.node,
            pubkey: .value(req.pubkey),
            fingerprint: .value(fingerprint(req.pubkey)),
            url: req.url.map { .value($0) } ?? .null,
            joinedAt: .value(Stamp.iso()),
            viaInvite: .value(inviteId),
            ourToken: .value(ourToken),
            theirToken: .value(req.offerToken)
        ))
        steps.append(AuditStep(n: 5, label: "issue a member token and store the membership", ok: true, detail: "invite \(inviteId) now used \(storedInvites[at].uses)/\(storedInvites[at].maxUses.map(String.init) ?? "∞")"))

        let entry = await record(.memberJoin, node: req.node, steps: steps, reason: nil, summary: "invite \(inviteId) · key \(fingerprint(req.pubkey))")
        return (memberToken: ourToken, entry: entry)
    }

    /// `fail()` in members.ts: push the failing step, record the rejection with
    /// `reason = code` and `summary = detail`, then throw.
    private func fail(_ code: RedeemFailure, _ label: String, _ detail: String, from node: String, steps: inout [AuditStep]) async -> RedeemError {
        steps.append(AuditStep(n: steps.count + 1, label: label, ok: false, detail: detail))
        await record(.redeemReject, node: node, steps: steps, reason: code.rawValue, summary: detail)
        return RedeemError(code: code, message: detail)
    }

    /// The other half: we redeemed somewhere, and now record who we joined.
    /// `summary` comes from the caller because the distinguishing fact on this
    /// side is which invite we spent, and that invite belongs to the other node.
    public func adopt(_ peer: AdoptedPeer, steps: [AuditStep], summary: String?) async -> AuditEntry {
        await upsert(MemberPatch(
            node: peer.node,
            pubkey: .value(peer.pubkey),
            fingerprint: .value(fingerprint(peer.pubkey)),
            url: peer.url.map { .value($0) } ?? .null,
            joinedAt: .value(Stamp.iso()),
            ourToken: .value(peer.ourToken),
            theirToken: .value(peer.theirToken)
        ))
        return await record(.memberJoin, node: peer.node, steps: steps, reason: nil, summary: summary ?? "we joined them · key \(fingerprint(peer.pubkey))")
    }

    /// A peer carried over from before tokens existed. Recorded as a member so
    /// the admin page can show it, flagged so the page can say it is unverified.
    public func adoptLegacy(node: String, url: String?) async {
        if storedMembers.contains(where: { $0.node == node }) { return }
        await upsert(MemberPatch(
            node: node,
            pubkey: .value(""),
            fingerprint: .value(""),
            url: url.map { .value($0) } ?? .null,
            joinedAt: .value(Stamp.iso()),
            legacy: .value(true)
        ))
    }

    /// `{ ...this.#members[at], ...member }` — every key the incoming record
    /// carries wins, including the ones whose value is undefined.
    private func upsert(_ patch: MemberPatch) async {
        if let at = storedMembers.firstIndex(where: { $0.node == patch.node }) {
            var merged = storedMembers[at]
            merged.node = patch.node
            // pubkey / fingerprint / joinedAt are never sent as undefined by any
            // caller; keeping the stored value is the harmless reading of that.
            if let v = patch.pubkey.value { merged.pubkey = v }
            if let v = patch.fingerprint.value { merged.fingerprint = v }
            if let v = patch.joinedAt.value { merged.joinedAt = v }
            merged.url = overwrite(merged.url, patch.url)
            merged.viaInvite = overwrite(merged.viaInvite, patch.viaInvite)
            merged.lastSeen = overwrite(merged.lastSeen, patch.lastSeen)
            merged.legacy = overwrite(merged.legacy, patch.legacy)
            merged.ourToken = overwrite(merged.ourToken, patch.ourToken)
            merged.theirToken = overwrite(merged.theirToken, patch.theirToken)
            // a real handshake retires the legacy flag: the record now has a proven key
            if truthy(patch.pubkey.value) { merged.legacy = nil }
            storedMembers[at] = merged
        } else {
            storedMembers.append(StoredMember(
                node: patch.node,
                pubkey: patch.pubkey.value ?? "",
                fingerprint: patch.fingerprint.value ?? "",
                url: patch.url.value,
                joinedAt: patch.joinedAt.value ?? "",
                viaInvite: patch.viaInvite.value,
                lastSeen: patch.lastSeen.value,
                legacy: patch.legacy.value,
                ourToken: patch.ourToken.value,
                theirToken: patch.theirToken.value
            ))
        }
        await save()
    }

    /// absent → keep, present-and-undefined → clear, present → overwrite
    private func overwrite<T: Codable & Sendable>(_ current: T?, _ patch: Nullable<T>) -> T? {
        switch patch {
        case .absent: return current
        case .null: return nil
        case .value(let v): return v
        }
    }

    /// Kick: the membership stops existing here. Their token dies with it, which
    /// is the whole difference from the old `leave()`.
    public func kick(node: String, reason: String?, adopted: String?) async -> AuditEntry? {
        guard let member = storedMembers.first(where: { $0.node == node }) else { return nil }
        storedMembers.removeAll { $0.node == node }
        await save()
        let via = truthy(member.viaInvite) ? member.viaInvite! : nil
        let summary: String
        if truthy(adopted) { summary = "adopted from \(adopted!)" }
        else if truthy(reason) { summary = reason! }
        else if let via { summary = "had joined via invite \(via)" }
        else { summary = "no reason given" }
        return await record(truthy(adopted) ? .kickAdopt : .memberKick, node: node, steps: [
            AuditStep(n: 1, label: "delete the membership", ok: true, detail: "joined \(member.joinedAt)\(via.map { " via invite \($0)" } ?? "")"),
            AuditStep(n: 2, label: "their token stops authenticating", ok: true, detail: "next /api/fed/* call from them answers 401"),
            AuditStep(n: 3, label: "stop pushing and pulling with them", ok: true, detail: "\(node) removed from peers.json"),
            AuditStep(n: 4, label: "publish the kick", ok: true, detail: truthy(adopted) ? "adopted from \(adopted!)" : "peers may adopt it; nothing makes them"),
        ], reason: reason, summary: summary)
    }

    /// Ban: the same as a kick, plus the pubkey is pinned so no invite lets it
    /// back. Banning a member therefore writes TWO audit entries, kick then ban.
    public func ban(node: String, reason: String?) async -> AuditEntry {
        let member = storedMembers.first(where: { $0.node == node })
        let pubkey = member?.pubkey ?? ""
        _ = await kick(node: node, reason: reason, adopted: nil)
        storedBans.append(BanRecord(node: node, pubkey: pubkey, at: Stamp.iso(), by: self.node, reason: reason))
        await save()
        return await record(.memberBan, node: node, steps: [
            AuditStep(n: 1, label: "pin the key", ok: true, detail: truthy(pubkey) ? "\(fingerprint(pubkey)) — every future redeem from this key is refused" : "no key on record (legacy peer) — the node NAME is pinned instead"),
            AuditStep(n: 2, label: "a valid invite no longer helps them", ok: true, detail: "this is the only difference from a kick"),
        ], reason: reason, summary: truthy(pubkey) ? "key \(fingerprint(pubkey)) pinned" : "node name pinned (no key on record)")
    }

    public func unban(node: String) async -> AuditEntry? {
        guard let ban = storedBans.first(where: { $0.node == node }) else { return nil }
        storedBans.removeAll { $0.node == node }
        await save()
        return await record(.memberUnban, node: node, steps: [
            AuditStep(n: 1, label: "unpin the key", ok: true, detail: truthy(ban.pubkey) ? fingerprint(ban.pubkey) : node),
            AuditStep(n: 2, label: "they still need a valid invite to return", ok: true, detail: "unban is not an invite"),
        ], reason: nil, summary: truthy(ban.pubkey) ? "key \(fingerprint(ban.pubkey)) unpinned" : "\(node) unpinned")
    }

    public func adoptKick(node: String, from: String, reason: String?) async -> AuditEntry? {
        await kick(node: node, reason: reason ?? "adopted from \(from)", adopted: from)
    }
}

/// `String(n)` for a JS number, for the one place an invite's `hours` is printed
/// back into an audit summary: 24 → "24", 0.5 → "0.5", never "24.0".
func jsNumberText(_ n: Double) -> String {
    if n.isNaN { return "NaN" }
    if n.isInfinite { return n > 0 ? "Infinity" : "-Infinity" }
    if n == n.rounded(), abs(n) < 1e21 { return String(Int64(n)) }
    return String(n)
}

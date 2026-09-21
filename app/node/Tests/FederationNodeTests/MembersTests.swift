import XCTest
@testable import FederationNode

/// Scratch state lives under `wt/swift-node/.tmp/` (gitignored), never beside
/// the real node's `.fed-*.json`. Derived from `#filePath` so it follows the
/// checkout instead of hardcoding a machine path:
/// `…/wt/swift-node/app/node/Tests/FederationNodeTests/MembersTests.swift` → 5 up.
private func scratchRoot() -> URL {
    var url = URL(fileURLWithPath: #filePath)
    for _ in 0..<5 { url.deleteLastPathComponent() }
    return url.appendingPathComponent(".tmp/members-tests", isDirectory: true)
}

/// A hand-written file in the layout the Bun node writes: pretty-printed,
/// `expiresAt`/`maxUses` explicit nulls, the two tokens on the member, `note`
/// and `revokedAt` simply absent. Every value here is invented for this test.
private let fixtureToken = "fixture-invite-secret-0000000000"
private let fixtureOurToken = "fixture-our-token-00000000000000"
private let fixtureTheirToken = "fixture-their-token-000000000000"
private let fixturePubkey = "17f98a50d3110324560a83f49a50cc4fa94af3541f0b54acaf421a864315bc69"
private let fixtureJSON = """
{
  "invites": [
    {
      "id": "inv00001",
      "token": "\(fixtureToken)",
      "createdAt": "2026-09-20T10:00:00.000Z",
      "createdBy": "alpha",
      "expiresAt": null,
      "maxUses": null,
      "uses": 1,
      "usedBy": [
        { "node": "bravo", "at": "2026-09-20T10:05:00.000Z" }
      ]
    }
  ],
  "members": [
    {
      "node": "bravo",
      "pubkey": "\(fixturePubkey)",
      "fingerprint": "17f98a50d3110324",
      "url": "http://bravo.test:6750",
      "joinedAt": "2026-09-20T10:05:00.000Z",
      "viaInvite": "inv00001",
      "ourToken": "\(fixtureOurToken)",
      "theirToken": "\(fixtureTheirToken)"
    },
    {
      "node": "charlie",
      "pubkey": "",
      "fingerprint": "",
      "url": "http://charlie.test:6750",
      "joinedAt": "2026-09-19T08:00:00.000Z",
      "legacy": true
    }
  ],
  "bans": [
    {
      "node": "delta",
      "pubkey": "aabbccddeeff00112233445566778899aabbccddeeff00112233445566778899",
      "at": "2026-09-18T09:00:00.000Z",
      "by": "alpha",
      "reason": "flooding"
    }
  ],
  "audit": [
    {
      "id": "aud00001",
      "at": "2026-09-18T09:00:00.000Z",
      "action": "member.kick",
      "node": "delta",
      "by": "alpha",
      "summary": "no reason given",
      "steps": [
        { "n": 1, "label": "delete the membership", "ok": true, "detail": "joined 2026-09-17T09:00:00.000Z" }
      ]
    }
  ]
}
"""

final class MembersTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = scratchRoot().appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let dir { try? FileManager.default.removeItem(at: dir) }
    }

    private func store(node: String = "alpha", base: String? = "http://alpha.test:6750", file: String = ".fed-members.json") -> Members {
        let path = dir.appendingPathComponent(file).path
        return Members(node: node, statePath: path, baseUrl: { base }, allowLegacy: true)
    }

    private func diskText(_ file: String = ".fed-members.json") throws -> String {
        try String(contentsOf: dir.appendingPathComponent(file), encoding: .utf8)
    }

    /// A joiner with a real keypair, so the signature step is exercised for real.
    private func joiner(_ name: String) throws -> NodeIdentity {
        try NodeIdentity.open(node: name, path: dir.appendingPathComponent("\(name)-identity.json").path)
    }

    private func redeemRequest(_ id: NodeIdentity, token: String, url: String? = nil, offerToken: String = "their-token", at: String = Stamp.iso()) -> FedRedeemRequest {
        let sig = id.sign(redeemMessage(token: token, node: id.node, at: at))
        return FedRedeemRequest(token: token, node: id.node, pubkey: id.pubkey, url: url, offerToken: offerToken, at: at, sig: sig)
    }

    /// members.ts does `hours * 3600_000` on whatever arrived, so a fractional
    /// `hours` is a real, shorter invite. Typing it as an Int made the body fail
    /// to decode and quietly issued the 24-hour default — 48x the ask. Measured
    /// on Bun: `{"hours":0.5}` → expiry +30 min, summary `· 0.5h ·`.
    func testFractionalHoursIsAShortInvite() async {
        let m = store()
        await m.load()
        let inv = await m.createInvite(CreateInviteRequest(hours: .value(0.5)))
        let expires = Stamp.parse(inv.expiresAt ?? "")?.timeIntervalSince1970 ?? 0
        XCTAssertEqual(expires * 1000 - Double(Stamp.nowMs()), 1_800_000, accuracy: 10_000)
        let summary = await m.audit().first?.summary ?? ""
        XCTAssertTrue(summary.contains("· 0.5h ·"), summary)
    }

    /// The default is still exactly a day, printed `24h` and not `24.0h`.
    func testDefaultInviteIsStillADayAndPrintsLikeJS() async {
        let m = store()
        await m.load()
        _ = await m.createInvite(CreateInviteRequest())
        let summary = await m.audit().first?.summary ?? ""
        XCTAssertTrue(summary.contains("· 24h ·"), summary)
    }

    /// members.ts:201 records the rejection under `req.node ?? "unknown"`: an
    /// ABSENT `node` key reads "unknown", an explicit "" stays "".
    func testRedeemRejectNamesAnAbsentNodeUnknown() async {
        let m = store()
        await m.load()
        let absent = FedRedeemRequest(token: "nope", node: "", pubkey: "", url: nil, offerToken: "", at: Stamp.iso(), sig: "", nodePresent: false)
        _ = try? await m.redeem(absent)
        var entry = await m.audit().first
        XCTAssertEqual(entry?.action, .redeemReject)
        XCTAssertEqual(entry?.node, "unknown")

        let empty = FedRedeemRequest(token: "nope", node: "", pubkey: "", url: nil, offerToken: "", at: Stamp.iso(), sig: "")
        _ = try? await m.redeem(empty)
        entry = await m.audit().first
        XCTAssertEqual(entry?.node, "", "an explicit empty node is NOT undefined")
    }

    // MARK: - the whole relationship, birth to kick

    func testCreatePreviewRedeemAuthenticateKick() async throws {
        let m = store()
        await m.load()

        // ── create ───────────────────────────────────────────────────────────
        let inv = await m.createInvite(CreateInviteRequest(hours: .absent, uses: .value(1), note: "for bravo"))
        XCTAssertEqual(inv.status, .active)
        XCTAssertEqual(inv.uses, 0)
        XCTAssertEqual(inv.maxUses, 1)
        XCTAssertEqual(inv.note, "for bravo")
        XCTAssertNotNil(inv.expiresAt)
        let token = try XCTUnwrap(inv.token)
        XCTAssertEqual(inv.url, "http://alpha.test:6750/join/\(token)")

        var audit = await m.audit()
        XCTAssertEqual(audit.count, 1)
        XCTAssertEqual(audit[0].action, .inviteCreate)
        XCTAssertEqual(audit[0].node, "alpha")
        XCTAssertEqual(audit[0].by, "alpha")
        XCTAssertEqual(audit[0].summary, "invite \(inv.id) · 24h · 1 uses")
        XCTAssertEqual(audit[0].steps.map(\.n), [1, 2, 3])
        XCTAssertEqual(audit[0].steps[0].label, "mint a secret")
        XCTAssertEqual(audit[0].steps[0].detail, "24 bytes, base64url · id \(inv.id)")
        XCTAssertEqual(audit[0].steps[1].detail, "expires \(inv.expiresAt!) · 1 uses")
        XCTAssertEqual(audit[0].steps[2].wire, inv.url)
        XCTAssertTrue(audit[0].steps[2].ok)

        // ── preview ──────────────────────────────────────────────────────────
        let previewed = await m.preview(token: token)
        let seen = try XCTUnwrap(previewed)
        XCTAssertEqual(seen.status, .active)
        XCTAssertEqual(seen.invite.id, inv.id)
        let miss = await m.preview(token: "not-a-token")
        XCTAssertNil(miss)

        // ── redeem ───────────────────────────────────────────────────────────
        let bravo = try joiner("bravo")
        let at = Stamp.iso()
        let (memberToken, entry) = try await m.redeem(redeemRequest(bravo, token: token, url: "http://bravo.test:6750", at: at))
        XCTAssertFalse(memberToken.isEmpty)
        XCTAssertEqual(entry.action, .memberJoin)
        XCTAssertEqual(entry.node, "bravo")
        XCTAssertEqual(entry.summary, "invite \(inv.id) · key \(fingerprint(bravo.pubkey))")
        XCTAssertEqual(entry.steps.map(\.n), [1, 2, 3, 4, 5])
        XCTAssertEqual(entry.steps.map(\.label), [
            "look the invite up",
            "check the invite is still good",
            "check the key is not banned",
            "verify the signature",
            "issue a member token and store the membership",
        ])
        XCTAssertEqual(entry.steps[0].detail, "id \(inv.id), created \(inv.createdAt)")
        XCTAssertEqual(entry.steps[1].detail, "expires \(inv.expiresAt!) · used 0/1")
        XCTAssertEqual(entry.steps[2].detail, fingerprint(bravo.pubkey))
        XCTAssertEqual(entry.steps[3].detail, "ed25519 over \"\(redeemMessage(token: token, node: "bravo", at: at))\"")
        XCTAssertEqual(entry.steps[4].detail, "invite \(inv.id) now used 1/1")
        XCTAssertTrue(entry.steps.allSatisfy(\.ok))

        // ── the membership, with the tokens kept off every view ──────────────
        let members = await m.members()
        XCTAssertEqual(members.count, 1)
        XCTAssertEqual(members[0].node, "bravo")
        XCTAssertEqual(members[0].pubkey, bravo.pubkey)
        XCTAssertEqual(members[0].fingerprint, fingerprint(bravo.pubkey))
        XCTAssertEqual(members[0].url, "http://bravo.test:6750")
        XCTAssertEqual(members[0].viaInvite, inv.id)
        XCTAssertNil(members[0].legacy)
        let view = try JSONCoding.encode(members)
        let viewText = String(decoding: view, as: UTF8.self)
        XCTAssertFalse(viewText.contains("ourToken"))
        XCTAssertFalse(viewText.contains("theirToken"))
        // on disk they ARE there — that is the whole point of StoredMember
        let disk = try diskText()
        XCTAssertTrue(disk.contains("\"ourToken\""))
        XCTAssertTrue(disk.contains("\"theirToken\""))
        let outbound = await m.tokenFor("bravo")
        XCTAssertEqual(outbound, "their-token")
        let unknownPeer = await m.tokenFor("nobody")
        XCTAssertNil(unknownPeer)

        // ── authenticate ─────────────────────────────────────────────────────
        let who = await m.authenticate(token: memberToken)
        XCTAssertEqual(who?.node, "bravo")
        XCTAssertNotNil(who?.lastSeen)
        let noToken = await m.authenticate(token: nil)
        XCTAssertNil(noToken)
        let emptyToken = await m.authenticate(token: "")
        XCTAssertNil(emptyToken)
        let wrongToken = await m.authenticate(token: "not-the-token")
        XCTAssertNil(wrongToken)

        // ── the invite is spent ──────────────────────────────────────────────
        let after = await m.invites()
        XCTAssertEqual(after.count, 1)
        XCTAssertEqual(after[0].status, .exhausted)
        XCTAssertEqual(after[0].uses, 1)
        XCTAssertEqual(after[0].usedBy.map(\.node), ["bravo"])

        do {
            _ = try await m.redeem(redeemRequest(bravo, token: token))
            XCTFail("a spent invite must not redeem twice")
        } catch let e as RedeemError {
            XCTAssertEqual(e.code, .exhausted)
            XCTAssertEqual(e.message, "invite is exhausted")
        }
        audit = await m.audit()
        XCTAssertEqual(audit[0].action, .redeemReject)
        XCTAssertEqual(audit[0].reason, "exhausted")
        XCTAssertEqual(audit[0].summary, "invite is exhausted")
        XCTAssertEqual(audit[0].steps.last?.n, 2)
        XCTAssertEqual(audit[0].steps.last?.ok, false)

        // ── kick ─────────────────────────────────────────────────────────────
        let kickEntry = await m.kick(node: "bravo", reason: nil, adopted: nil)
        let kicked = try XCTUnwrap(kickEntry)
        XCTAssertEqual(kicked.action, .memberKick)
        XCTAssertEqual(kicked.summary, "had joined via invite \(inv.id)")
        XCTAssertEqual(kicked.steps.map(\.n), [1, 2, 3, 4])
        XCTAssertEqual(kicked.steps[1].detail, "next /api/fed/* call from them answers 401")
        XCTAssertEqual(kicked.steps[2].detail, "bravo removed from peers.json")
        XCTAssertEqual(kicked.steps[3].detail, "peers may adopt it; nothing makes them")
        let goneMembers = await m.members()
        XCTAssertTrue(goneMembers.isEmpty)

        // the 401-equivalent: their token stops authenticating
        let dead = await m.authenticate(token: memberToken)
        XCTAssertNil(dead)
        let kickAgain = await m.kick(node: "bravo", reason: nil, adopted: nil)
        XCTAssertNil(kickAgain)

        // ── ban a node that was never a member, then unban ───────────────────
        let auditBefore = await m.audit()
        let banned = await m.ban(node: "ghost", reason: "never met, not welcome")
        XCTAssertEqual(banned.action, .memberBan)
        XCTAssertEqual(banned.summary, "node name pinned (no key on record)")
        XCTAssertEqual(banned.reason, "never met, not welcome")
        XCTAssertEqual(banned.steps[0].detail, "no key on record (legacy peer) — the node NAME is pinned instead")
        let auditAfter = await m.audit()
        // a ban of a NON-member writes exactly one entry: kick found nobody
        XCTAssertEqual(auditAfter.count, auditBefore.count + 1)
        let bans = await m.bans()
        XCTAssertEqual(bans.count, 1)
        XCTAssertEqual(bans[0].node, "ghost")
        XCTAssertEqual(bans[0].pubkey, "")
        XCTAssertEqual(bans[0].by, "alpha")
        let byName = await m.isBanned(pubkey: "whatever", node: "ghost")
        XCTAssertTrue(byName)
        let notBanned = await m.isBanned(pubkey: "whatever", node: "someone-else")
        XCTAssertFalse(notBanned)

        let unbanEntry = await m.unban(node: "ghost")
        let unbanned = try XCTUnwrap(unbanEntry)
        XCTAssertEqual(unbanned.action, .memberUnban)
        XCTAssertEqual(unbanned.summary, "ghost unpinned")
        XCTAssertEqual(unbanned.steps[0].detail, "ghost")
        let unbanTwice = await m.unban(node: "ghost")
        XCTAssertNil(unbanTwice)

        // ── revoke ───────────────────────────────────────────────────────────
        let revokeEntryLink = await m.revokeInvite(inv.id)
        let revoked = try XCTUnwrap(revokeEntryLink)
        XCTAssertEqual(revoked.status, .revoked)
        XCTAssertNotNil(revoked.revokedAt)
        let revokeTwice = await m.revokeInvite(inv.id)
        XCTAssertNil(revokeTwice)
        let revokeUnknown = await m.revokeInvite("nope")
        XCTAssertNil(revokeUnknown)
        let revokeEntry = await m.audit()
        XCTAssertEqual(revokeEntry[0].action, .inviteRevoke)
        XCTAssertEqual(revokeEntry[0].summary, "invite \(inv.id) · used 1×")
        XCTAssertEqual(revokeEntry[0].steps[1].detail, "bravo")

        // ── it all survives a reload ─────────────────────────────────────────
        let again = store()
        await again.load()
        let reloaded = await again.invites()
        XCTAssertEqual(reloaded.count, 1)
        XCTAssertEqual(reloaded[0].id, inv.id)
        XCTAssertEqual(reloaded[0].status, .revoked)
        let reloadedBans = await again.bans()
        XCTAssertTrue(reloadedBans.isEmpty)
        let reloadedAudit = await again.audit()
        XCTAssertEqual(reloadedAudit.count, revokeEntry.count)
    }

    // MARK: - the refusals, with their exact texts

    func testRedeemRefusals() async throws {
        let m = store()
        await m.load()
        let inv = await m.createInvite(CreateInviteRequest())
        let token = try XCTUnwrap(inv.token)
        let echo = try joiner("echo")

        // self
        let selfSig = FedRedeemRequest(token: token, node: "alpha", pubkey: echo.pubkey, url: nil, offerToken: "t", at: Stamp.iso(), sig: "x")
        await assertRefused(.self, "that invite belongs to this node") { _ = try await m.redeem(selfSig) }

        // unknown invite
        await assertRefused(.unknownInvite, "no invite with that secret") {
            _ = try await m.redeem(self.redeemRequest(echo, token: "no-such-secret"))
        }

        // expired — an invite minted an hour in the past
        let stale = await m.createInvite(CreateInviteRequest(hours: .value(-1)))
        XCTAssertEqual(stale.status, .expired)
        let staleToken = try XCTUnwrap(stale.token)
        await assertRefused(.expired, "invite is expired") {
            _ = try await m.redeem(self.redeemRequest(echo, token: staleToken))
        }

        // revoked
        let doomed = await m.createInvite(CreateInviteRequest())
        _ = await m.revokeInvite(doomed.id)
        let doomedToken = try XCTUnwrap(doomed.token)
        await assertRefused(.revoked, "invite is revoked") {
            _ = try await m.redeem(self.redeemRequest(echo, token: doomedToken))
        }

        // banned
        _ = await m.ban(node: "echo", reason: "test")
        await assertRefused(.banned, "echo is banned on this node") {
            _ = try await m.redeem(self.redeemRequest(echo, token: token))
        }
        _ = await m.unban(node: "echo")

        // stale request — the window, and the rounded age, verbatim
        let old = Stamp.iso(Date(timeIntervalSinceNow: -600))
        await assertRefused(.staleRequest, "signed 600s ago — window is 300s") {
            _ = try await m.redeem(self.redeemRequest(echo, token: token, at: old))
        }
        // an unparseable `at` is NaN in the Bun original, and prints as one
        await assertRefused(.staleRequest, "signed NaNs ago — window is 300s") {
            _ = try await m.redeem(self.redeemRequest(echo, token: token, at: "not a date"))
        }

        // bad signature — signed over a different message
        let at = Stamp.iso()
        let wrong = FedRedeemRequest(token: token, node: "echo", pubkey: echo.pubkey, url: nil, offerToken: "t", at: at, sig: echo.sign("something else"))
        await assertRefused(.badSignature, "signature does not match the offered key") { _ = try await m.redeem(wrong) }

        // every refusal is on the record, and none of them minted a member
        let members = await m.members()
        XCTAssertTrue(members.isEmpty)
        let rejects = await m.audit()
        XCTAssertEqual(rejects.filter { $0.action == .redeemReject }.count, 8)
        // the failing step of a stale/bad-signature request is n:4 — members.ts
        // pushes no success step for freshness, so 4 is used twice
        let sigReject = try XCTUnwrap(rejects.first { $0.reason == RedeemFailure.badSignature.rawValue })
        XCTAssertEqual(sigReject.steps.count, 4)
        XCTAssertEqual(sigReject.steps.last?.n, 4)
        XCTAssertEqual(sigReject.steps.last?.ok, false)
    }

    private func assertRefused(_ code: RedeemFailure, _ message: String, _ body: () async throws -> Void, file: StaticString = #filePath, line: UInt = #line) async {
        do {
            try await body()
            XCTFail("expected \(code.rawValue)", file: file, line: line)
        } catch let e as RedeemError {
            XCTAssertEqual(e.code, code, file: file, line: line)
            XCTAssertEqual(e.message, message, file: file, line: line)
        } catch {
            XCTFail("expected RedeemError, got \(error)", file: file, line: line)
        }
    }

    // MARK: - invite terms

    func testInviteTerms() async throws {
        let m = store(base: nil)
        await m.load()

        // hours null = never expires, uses null = unlimited
        let forever = await m.createInvite(CreateInviteRequest(hours: .null, uses: .null))
        XCTAssertNil(forever.expiresAt)
        XCTAssertNil(forever.maxUses)
        XCTAssertEqual(forever.status, .active)
        // no base url → no link at all
        XCTAssertNil(forever.url)
        let audit = await m.audit()
        XCTAssertEqual(audit[0].summary, "invite \(forever.id) · no expiry · ∞ uses")
        XCTAssertEqual(audit[0].steps[1].detail, "never expires · unlimited uses")
        XCTAssertEqual(audit[0].steps[2].wire, "(this node is not reachable — no link)")
        XCTAssertFalse(audit[0].steps[2].ok)

        // an unlimited invite never exhausts
        let hotel = try joiner("hotel")
        let india = try joiner("india")
        let token = try XCTUnwrap(forever.token)
        _ = try await m.redeem(redeemRequest(hotel, token: token))
        _ = try await m.redeem(redeemRequest(india, token: token))
        let after = await m.invites()
        XCTAssertEqual(after[0].uses, 2)
        XCTAssertEqual(after[0].status, .active)
        XCTAssertEqual(after[0].usedBy.map(\.node), ["hotel", "india"])

        // newest first
        let second = await m.createInvite(CreateInviteRequest(hours: .value(2), uses: .value(5), note: nil))
        let list = await m.invites()
        XCTAssertEqual(list.map(\.id), [second.id, forever.id])
        let summaries = await m.audit()
        XCTAssertEqual(summaries[0].summary, "invite \(second.id) · 2h · 5 uses")
    }

    // MARK: - the two-entry ban, and the spread rule in #upsert

    func testBanOfAMemberWritesKickThenBan() async throws {
        let m = store()
        await m.load()
        let juliet = try joiner("juliet")
        _ = await m.adopt(AdoptedPeer(node: "juliet", pubkey: juliet.pubkey, url: "http://juliet.test:6750", ourToken: secret(), theirToken: secret()), steps: [], summary: nil)

        let joined = await m.audit()
        XCTAssertEqual(joined[0].action, .memberJoin)
        XCTAssertEqual(joined[0].summary, "we joined them · key \(fingerprint(juliet.pubkey))")

        let entry = await m.ban(node: "juliet", reason: "loud")
        XCTAssertEqual(entry.action, .memberBan)
        XCTAssertEqual(entry.summary, "key \(fingerprint(juliet.pubkey)) pinned")
        XCTAssertEqual(entry.steps[0].detail, "\(fingerprint(juliet.pubkey)) — every future redeem from this key is refused")

        // TWO entries, kick then ban — the Bun original calls kick() inside ban()
        let audit = await m.audit()
        XCTAssertEqual(audit[0].action, .memberBan)
        XCTAssertEqual(audit[1].action, .memberKick)
        XCTAssertEqual(audit[1].summary, "loud")
        XCTAssertEqual(audit[2].action, .memberJoin)

        // both are published to peers, oldest first
        let published = await m.publishedKicks()
        XCTAssertEqual(published.map(\.action), [.memberKick, .memberBan])

        // the ban pins the key, so the same key cannot redeem a fresh invite
        let inv = await m.createInvite(CreateInviteRequest())
        let inviteToken = try XCTUnwrap(inv.token)
        await assertRefused(.banned, "juliet is banned on this node") {
            _ = try await m.redeem(self.redeemRequest(juliet, token: inviteToken))
        }
    }

    func testAdoptLegacyAndUpsertSpread() async throws {
        let m = store()
        await m.load()

        await m.adoptLegacy(node: "kilo", url: "http://kilo.test:6750")
        var members = await m.members()
        XCTAssertEqual(members.count, 1)
        XCTAssertEqual(members[0].legacy, true)
        XCTAssertEqual(members[0].pubkey, "")
        XCTAssertEqual(members[0].url, "http://kilo.test:6750")

        // an existing member is never touched by adoptLegacy
        await m.adoptLegacy(node: "kilo", url: "http://somewhere-else:6750")
        members = await m.members()
        XCTAssertEqual(members[0].url, "http://kilo.test:6750")

        // a real handshake retires the legacy flag — and `url: undefined` in the
        // incoming record CLEARS the stored url, because the JS spread copies
        // undefined keys too
        let kilo = try joiner("kilo")
        _ = await m.adopt(AdoptedPeer(node: "kilo", pubkey: kilo.pubkey, url: nil, ourToken: secret(), theirToken: secret()), steps: [], summary: "we joined them")
        members = await m.members()
        XCTAssertEqual(members.count, 1)
        XCTAssertNil(members[0].legacy)
        XCTAssertNil(members[0].url)
        XCTAssertEqual(members[0].pubkey, kilo.pubkey)

        // adoptKick: the reason defaults to the peer we adopted it from
        let adoptedKick = await m.adoptKick(node: "kilo", from: "lima", reason: nil)
        let adopted = try XCTUnwrap(adoptedKick)
        XCTAssertEqual(adopted.action, .kickAdopt)
        XCTAssertEqual(adopted.reason, "adopted from lima")
        XCTAssertEqual(adopted.summary, "adopted from lima")
        XCTAssertEqual(adopted.steps[3].detail, "adopted from lima")
        // an adopted kick is NOT republished — only member.kick and member.ban are
        let published = await m.publishedKicks()
        XCTAssertTrue(published.isEmpty)
        let missing = await m.adoptKick(node: "kilo", from: "lima", reason: nil)
        XCTAssertNil(missing)
    }

    // MARK: - reading what the Bun node wrote

    func testLoadsBunLayout() async throws {
        let path = dir.appendingPathComponent(".fed-members.json")
        try fixtureJSON.write(to: path, atomically: true, encoding: .utf8)
        let m = store()
        await m.load()

        let invites = await m.invites()
        XCTAssertEqual(invites.count, 1)
        XCTAssertEqual(invites[0].id, "inv00001")
        XCTAssertNil(invites[0].expiresAt)         // explicit null → never expires
        XCTAssertNil(invites[0].maxUses)           // explicit null → unlimited
        XCTAssertNil(invites[0].note)              // absent key
        XCTAssertNil(invites[0].revokedAt)
        XCTAssertEqual(invites[0].uses, 1)
        XCTAssertEqual(invites[0].status, .active)
        XCTAssertEqual(invites[0].url, "http://alpha.test:6750/join/\(fixtureToken)")

        let previewed = await m.preview(token: fixtureToken)
        let preview = try XCTUnwrap(previewed)
        XCTAssertEqual(preview.status, .active)
        XCTAssertEqual(preview.invite.createdBy, "alpha")

        let members = await m.members()
        XCTAssertEqual(members.map(\.node), ["bravo", "charlie"])
        XCTAssertEqual(members[0].viaInvite, "inv00001")
        XCTAssertEqual(members[1].legacy, true)
        let viewText = String(decoding: try JSONCoding.encode(members), as: UTF8.self)
        XCTAssertFalse(viewText.contains("ourToken"))
        XCTAssertFalse(viewText.contains("theirToken"))

        // the stored tokens are still usable in both directions
        let outbound = await m.tokenFor("bravo")
        XCTAssertEqual(outbound, fixtureTheirToken)
        let who = await m.authenticate(token: fixtureOurToken)
        XCTAssertEqual(who?.node, "bravo")
        let emptyToken = await m.authenticate(token: "")
        XCTAssertNil(emptyToken)

        let bans = await m.bans()
        XCTAssertEqual(bans.map(\.node), ["delta"])
        let byKey = await m.isBanned(pubkey: "aabbccddeeff00112233445566778899aabbccddeeff00112233445566778899", node: "anyone")
        XCTAssertTrue(byKey)

        let audit = await m.audit()
        XCTAssertEqual(audit.count, 1)
        XCTAssertEqual(audit[0].action, .memberKick)
        XCTAssertEqual(audit[0].steps.count, 1)
        let published = await m.publishedKicks()
        XCTAssertEqual(published.map(\.id), ["aud00001"])

        // a save() round-trips the same four arrays, tokens included — in the
        // layout members.ts writes: `JSON.stringify({invites, members, bans, audit}, null, 2)`
        await m.save()
        let disk = try diskText()
        XCTAssertTrue(disk.hasPrefix("{\n  \"invites\": [\n    {\n      \"id\": \"inv00001\",\n      \"token\": \""), String(disk.prefix(60)))
        XCTAssertTrue(disk.contains("      \"expiresAt\": null,\n      \"maxUses\": null,\n      \"uses\": 1,\n"))
        XCTAssertTrue(disk.contains("\n  \"members\": [\n    {\n      \"node\": \"bravo\",\n      \"pubkey\": \""))
        XCTAssertTrue(disk.hasSuffix("\n  ]\n}"))
        let back = store()
        await back.load()
        let backMembers = await back.members()
        XCTAssertEqual(backMembers.map(\.node), ["bravo", "charlie"])
        let backToken = await back.tokenFor("bravo")
        XCTAssertEqual(backToken, fixtureTheirToken)
    }

    func testLoadToleratesMissingAndBrokenFiles() async throws {
        let first = store(file: "never-written.json")
        await first.load()
        let none = await first.members()
        XCTAssertTrue(none.isEmpty)
        let noInvites = await first.invites()
        XCTAssertTrue(noInvites.isEmpty)

        let brokenPath = dir.appendingPathComponent("broken.json")
        try "{ not json at all".write(to: brokenPath, atomically: true, encoding: .utf8)
        let second = store(file: "broken.json")
        await second.load()
        let stillNone = await second.members()
        XCTAssertTrue(stillNone.isEmpty)

        // missing arrays are `?? []`, not a failure
        let partialPath = dir.appendingPathComponent("partial.json")
        try "{ \"members\": [] }".write(to: partialPath, atomically: true, encoding: .utf8)
        let third = store(file: "partial.json")
        await third.load()
        let emptyAudit = await third.audit()
        XCTAssertTrue(emptyAudit.isEmpty)
        let entry = await third.record(.memberJoin, node: "mike", steps: [], reason: nil, summary: nil)
        XCTAssertEqual(entry.by, "alpha")
        XCTAssertEqual(entry.id.count, 8)
        let oneEntry = await third.audit()
        XCTAssertEqual(oneEntry.count, 1)
    }

    func testAuditIsCappedAt500() async throws {
        let m = store()
        await m.load()
        for i in 0..<Const.auditCap + 20 {
            _ = await m.record(.memberJoin, node: "n\(i)", steps: [], reason: nil, summary: "\(i)")
        }
        let audit = await m.audit()
        XCTAssertEqual(audit.count, Const.auditCap)
        XCTAssertEqual(audit[0].summary, "\(Const.auditCap + 19)")   // newest first
        XCTAssertEqual(audit.last?.summary, "20")
        let published = await m.publishedKicks()
        XCTAssertTrue(published.isEmpty)
    }
}

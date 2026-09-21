import XCTest
@testable import FederationNode

/// federation.ts's semantics, pinned without a network: the log and its dedup,
/// the health MERGE, addPeer's "evidence beats a claim", leave taking a hub's
/// relayed nodes with it, and the relayed/gossip rebuild a pull performs.
///
/// Every `await` is hoisted out of the XCTAssert autoclosures — they are not
/// async, so a bare `XCTAssertEqual(await f.x(), y)` does not compile.
final class FederationTests: XCTestCase {
    // MARK: scratch

    /// `<wt>/swift-node/.tmp` — gitignored. Never the real `.fed-*.json`.
    private static let scratch: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // FederationNodeTests
        .deletingLastPathComponent()   // Tests
        .deletingLastPathComponent()   // node
        .deletingLastPathComponent()   // app
        .deletingLastPathComponent()   // swift-node
        .appendingPathComponent(".tmp")

    private var made: [String] = []

    private func statePath(_ name: String = UUID().uuidString) -> String {
        try? FileManager.default.createDirectory(at: Self.scratch, withIntermediateDirectories: true)
        let p = Self.scratch.appendingPathComponent("fed-test-\(name).json").path
        made.append(p)
        return p
    }

    override func tearDown() {
        for p in made { try? FileManager.default.removeItem(atPath: p) }
        made = []
        super.tearDown()
    }

    private func fed(
        node: String = "alpha",
        peers: [Peer] = [],
        gossip: Bool? = nil,
        path: String? = nil
    ) -> Federation {
        Federation(
            config: FedConfig(node: node, gossip: gossip, peers: peers),
            statePath: path ?? statePath()
        )
    }

    private func msg(_ id: String, node: String, seq: Int, text: String = "hi") -> FedMessage {
        FedMessage(id: id, node: node, seq: seq, from: node, text: text, at: Stamp.iso())
    }

    // MARK: - post / accept / disk

    func testPostAssignsOriginIdsAndPersists() async throws {
        let path = statePath()
        let f = fed(path: path)
        let a = await f.post(from: "alpha", text: "one")
        let b = await f.post(from: "nat", text: "two")
        XCTAssertEqual(a.id, "alpha:1")
        XCTAssertEqual(a.node, "alpha")
        XCTAssertEqual(a.seq, 1)
        XCTAssertEqual(b.id, "alpha:2")
        XCTAssertEqual(b.from, "nat")
        let all = await f.messages()
        XCTAssertEqual(all.map(\.id), ["alpha:1", "alpha:2"])

        // on disk: `JSON.stringify({ seq, messages })` — compact, that key
        // order, no escaped slashes, the message literal's order inside.
        let raw = try XCTUnwrap(FileManager.default.contents(atPath: path))
        let text = String(decoding: raw, as: UTF8.self)
        XCTAssertFalse(text.contains("\n"), "compact, never pretty")
        XCTAssertTrue(text.hasPrefix("{\"seq\":2,\"messages\":[{\"id\":\"alpha:1\",\"node\":\"alpha\",\"seq\":1,\"from\":\"alpha\",\"text\":\"one\",\"at\":\""), text)
        let saved = try JSONCoding.decode(SavedFedState.self, from: raw)
        XCTAssertEqual(saved.seq, 2)
        XCTAssertEqual(saved.messages?.map(\.id), ["alpha:1", "alpha:2"])

        // a fresh node over the same file keeps counting where the old one stopped
        let reopened = fed(path: path)
        await reopened.load()
        let loaded = await reopened.messages()
        XCTAssertEqual(loaded.count, 2)
        let c = await reopened.post(from: "alpha", text: "three")
        XCTAssertEqual(c.id, "alpha:3")
    }

    func testLoadToleratesAMissingFile() async {
        // a fresh uuid path — nothing there yet, and tearDown takes it away
        // again (the first `post` below creates it)
        let f = fed()
        await f.load()
        let empty = await f.messages()
        XCTAssertEqual(empty.count, 0)
        let m = await f.post(from: "alpha", text: "first run")
        XCTAssertEqual(m.id, "alpha:1")
    }

    func testMessagesAreCappedAndAnAgedOutIdNeverComesBack() async {
        let f = fed()
        for _ in 0..<(Const.messagesCap + 20) { _ = await f.post(from: "alpha", text: "x") }
        let all = await f.messages()
        XCTAssertEqual(all.count, Const.messagesCap)
        XCTAssertEqual(all.first?.id, "alpha:21")
        // the id set is never trimmed with the log, so message 1 can never return
        let added = await f.ingest([msg("alpha:1", node: "alpha", seq: 1)], from: nil)
        XCTAssertEqual(added, 0)
    }

    // MARK: - ingest

    func testIngestDedupsByOriginIdAndLearnsWhoSpoke() async {
        let f = fed()
        let batch = [msg("bravo:1", node: "bravo", seq: 1), msg("bravo:2", node: "bravo", seq: 2)]
        let first = await f.ingest(batch, from: IngestFrom(node: "bravo", url: "http://b:6750"))
        XCTAssertEqual(first, 2)
        // exact dedup by id — the same batch again adds nothing
        let again = await f.ingest(batch, from: IngestFrom(node: "bravo", url: "http://b:6750"))
        XCTAssertEqual(again, 0)

        let known = await f.known()
        XCTAssertEqual(known["bravo"]?.url, "http://b:6750")
        XCTAssertNotNil(known["bravo"]?.lastHeard)
    }

    func testIngestLearnsOriginNodesWithoutAUrlAndSkipsUs() async {
        let f = fed()
        let added = await f.ingest([
            msg("charlie:7", node: "charlie", seq: 7),
            msg("alpha:99", node: "alpha", seq: 99),   // one of ours, relayed back
        ], from: IngestFrom(node: "alpha", url: "http://us"))   // ourselves — ignored
        XCTAssertEqual(added, 2)
        let known = await f.known()
        XCTAssertNotNil(known["charlie"])
        XCTAssertNil(known["charlie"]?.url, "a message origin carries no address")
        XCTAssertNil(known["alpha"], "we are never in our own known map")
    }

    /// `/api/status.known` and `/api/admin.heard` are `Object.values(fed.known)` —
    /// a JSON ARRAY, so the order is on the wire and is what the console draws.
    /// A Swift Dictionary's order is seeded per process; this is insertion order.
    func testKnownListIsInsertionOrderNotHashOrder() async {
        let f = fed()
        _ = await f.ingest([msg("zulu:1", node: "zulu", seq: 1)], from: IngestFrom(node: "hub", url: "http://hub"))
        _ = await f.ingest([msg("delta:1", node: "delta", seq: 1)], from: IngestFrom(node: "other", url: nil))
        // `from` is stamped first, then each message's origin — twice over
        let order = await f.knownList().map(\.node)
        XCTAssertEqual(order, ["hub", "zulu", "other", "delta"])
        // and the dictionary view still holds exactly the same set
        let asDict = await f.known()
        XCTAssertEqual(Set(asDict.keys), Set(order))
        // re-hearing a node keeps its slot rather than moving it to the end
        _ = await f.ingest([msg("zulu:2", node: "zulu", seq: 2)], from: IngestFrom(node: "hub", url: "http://hub"))
        let again = await f.knownList().map(\.node)
        XCTAssertEqual(again, ["hub", "zulu", "other", "delta"])
    }

    // MARK: - health merge

    func testMarkMergesInsteadOfReplacing() async {
        let f = fed()
        await f.addPeer(name: "m5", url: "http://lan:6750")
        await f.mark("m5", ok: true)
        var h = await f.health()["m5"]
        XCTAssertEqual(h?.ok, true)
        XCTAssertEqual(h?.consecutive, 0)
        XCTAssertEqual(h?.lastOkUrl, "http://lan:6750")
        let okAt = h?.lastOkAt
        XCTAssertNotNil(okAt)
        XCTAssertEqual(h?.lastSeen, okAt)

        // a failure must not erase the success the other direction recorded
        await f.mark("m5", ok: false, error: "Error: 401")
        h = await f.health()["m5"]
        XCTAssertEqual(h?.ok, false)
        XCTAssertEqual(h?.lastError, "Error: 401")
        XCTAssertNotNil(h?.lastErrorAt)
        XCTAssertEqual(h?.consecutive, 1)
        XCTAssertEqual(h?.lastOkAt, okAt, "lastOkAt survives a failure")
        XCTAssertEqual(h?.lastOkUrl, "http://lan:6750", "the proven address survives a failure")

        await f.mark("m5", ok: false, error: "Error: 500")
        h = await f.health()["m5"]
        XCTAssertEqual(h?.consecutive, 2)

        // and a success clears the error entirely
        await f.mark("m5", ok: true)
        h = await f.health()["m5"]
        XCTAssertEqual(h?.consecutive, 0)
        XCTAssertNil(h?.lastError)
        XCTAssertNil(h?.lastErrorAt)
    }

    func testMarkKeepsThePreviousProvenUrlWhenThePeerIsGone() async {
        let f = fed()
        await f.mark("ghost", ok: true)          // never a peer — nothing to learn
        let h = await f.health()["ghost"]
        XCTAssertEqual(h?.ok, true)
        XCTAssertNil(h?.lastOkUrl)
    }

    // MARK: - addPeer: evidence beats a claim

    func testAddPeerAppendsAnUnknownNode() async {
        let f = fed()
        await f.addPeer(name: "m5", url: "http://lan:6750")
        let names = await f.peers().map(\.name)
        XCTAssertEqual(names, ["m5"])
        let p = await f.peer("m5")
        XCTAssertEqual(p?.url, "http://lan:6750")
    }

    func testAddPeerFillsAnEmptyAddress() async {
        let f = fed()
        await f.addPeer(name: "m5", url: "")           // redeem with no advertised url
        var p = await f.peer("m5")
        XCTAssertEqual(p?.url, "")
        await f.addPeer(name: "m5", url: "http://lan:6750")
        p = await f.peer("m5")
        XCTAssertEqual(p?.url, "http://lan:6750")
    }

    func testAddPeerTakesTheClaimWhenNothingHasEverWorked() async {
        let f = fed()
        await f.addPeer(name: "m5", url: "http://lan:6750")
        // no health yet — right after a restart this is the normal state
        await f.addPeer(name: "m5", url: "http://100.x:6750")
        let p = await f.peer("m5")
        XCTAssertEqual(p?.url, "http://100.x:6750")
    }

    func testAddPeerRefusesToTradeAProvenAddressForAnAdvertisedOne() async {
        let f = fed()
        await f.addPeer(name: "m5", url: "http://lan:6750")
        await f.mark("m5", ok: true)                            // the LAN address is now evidence
        await f.addPeer(name: "m5", url: "http://100.x:6750")   // m5's advertised NetBird IP
        let p = await f.peer("m5")
        XCTAssertEqual(p?.url, "http://lan:6750",
                       "an address that completed a sync is never traded for a claim")
    }

    func testAddPeerTreatsAnEmptyProvenUrlAsNoEvidence() async {
        // JS truthiness: lastOkUrl "" is falsy, so the claim wins.
        let f = fed()
        await f.addPeer(name: "m5", url: "")
        await f.mark("m5", ok: true)                       // lastOkUrl becomes ""
        let proven = await f.health()["m5"]?.lastOkUrl
        XCTAssertEqual(proven, "")
        await f.addPeer(name: "m5", url: "http://lan:6750")
        let p = await f.peer("m5")
        XCTAssertEqual(p?.url, "http://lan:6750")
    }

    // MARK: - config / peers

    func testConfigPeersStayInSyncAndDropVia() async {
        let f = fed(peers: [Peer(name: "hub", url: "http://hub", via: "someone")], gossip: true)
        var cfg = await f.config()
        XCTAssertEqual(cfg.peers.count, 1)
        XCTAssertEqual(cfg.gossip, true)
        XCTAssertEqual(cfg.node, "alpha")

        await f.addPeer(name: "m5", url: "http://lan")
        cfg = await f.config()
        XCTAssertEqual(cfg.peers.map(\.name), ["hub", "m5"])
        XCTAssertNil(cfg.peers[0].via, "peers.json only ever carries {name,url}")

        await f.leave("hub")
        cfg = await f.config()
        XCTAssertEqual(cfg.peers.map(\.name), ["m5"])
    }

    func testCallRefusesANodeThatIsNotADirectPeer() async {
        let f = fed(peers: [Peer(name: "hub", url: "http://hub")])
        do {
            _ = try await f.call("far", path: "/api/fed/hey", method: "POST", body: nil)
            XCTFail("expected a throw")
        } catch let err as FederationError {
            XCTAssertEqual(err.message, "far is not a direct peer of alpha")
            XCTAssertEqual(errorText(err), "far is not a direct peer of alpha")
        } catch {
            XCTFail("wrong error: \(error)")
        }
    }

    // MARK: - what a failed peer call says

    func testARefusedConnectionReadsLikeBunsFetch() async {
        // port 1 is closed on loopback: ECONNREFUSED at once
        let f = fed()
        do {
            _ = try await f.join(url: "http://127.0.0.1:1/")
            XCTFail("expected a throw")
        } catch let err as FederationError {
            XCTAssertEqual(err.message, "Unable to connect. Is the computer able to access the url?")
            XCTAssertEqual(err.description, "Error: Unable to connect. Is the computer able to access the url?")
            XCTAssertEqual(errorText(err), "Unable to connect. Is the computer able to access the url?")
        } catch {
            XCTFail("wrong error: \(error)")
        }
        // and the health record after a failed pull carries `String(err)`
        await f.addPeer(name: "dead", url: "http://127.0.0.1:1")
        await f.pullAll()
        let h = await f.health()["dead"]
        XCTAssertEqual(h?.ok, false)
        XCTAssertEqual(h?.consecutive, 1)
        XCTAssertEqual(h?.lastError, "Error: Unable to connect. Is the computer able to access the url?")
        let stats = await f.stats()
        XCTAssertEqual(stats.pullErrors, 1)
    }

    // MARK: - the hub model

    /// What a hub answers on `/api/fed/state`, hand-written — no network.
    private func hubState(
        node: String = "hub",
        messages: [FedMessage] = [],
        members: [Member] = [],
        peers: [PeerView] = [],
        relayed: [String: RelayedPeer]? = nil
    ) -> FedState {
        FedState(node: node, identity: nil, messages: messages, members: members,
                 peers: peers, federated: [], kicks: [], relayed: relayed)
    }

    func testApplyStateRebuildsRelayedFromScratch() async {
        let hub = Peer(name: "hub", url: "http://hub:6750")
        let f = fed(peers: [hub])
        let state = hubState(
            messages: [msg("hub:1", node: "hub", seq: 1)],
            members: [Member(handle: "neo", kind: "claude", pane: "w2V:p3")],
            relayed: [
                "spoke": RelayedPeer(url: "http://spoke",
                                     members: [Member(handle: "pulse", kind: "claude", pane: "w1:p1")],
                                     ok: true, lastOkAt: "2026-09-22T04:00:00.000Z", consecutive: 0),
                "alpha": RelayedPeer(url: "http://us", members: [], ok: true, lastOkAt: nil, consecutive: 0),
                "hub":   RelayedPeer(url: "http://hub", members: [], ok: true, lastOkAt: nil, consecutive: 0),
            ]
        )
        await f.applyState(state, from: hub)

        let relayed = await f.relayed()
        XCTAssertEqual(Set(relayed.keys), ["spoke"], "never ourselves, never a direct peer")
        XCTAssertEqual(relayed["spoke"]?.via, "hub")
        XCTAssertEqual(relayed["spoke"]?.url, "http://spoke")
        XCTAssertEqual(relayed["spoke"]?.members.map(\.handle), ["pulse"])
        XCTAssertEqual(relayed["spoke"]?.ok, true)
        XCTAssertEqual(relayed["spoke"]?.consecutive, 0)

        // rosters, ui url, health and the counters a pull moves
        let rosters = await f.peerMembers()
        XCTAssertEqual(rosters["hub"]?.map(\.handle), ["neo"])
        let ui = await f.peerUi()
        XCTAssertEqual(ui["hub"], "http://hub:6750")
        let federated = await f.peerFederated()
        XCTAssertEqual(federated["hub"]?.count, 0)
        let kicks = await f.peerKicks()
        XCTAssertEqual(kicks["hub"]?.count, 0)
        let health = await f.health()
        XCTAssertEqual(health["hub"]?.ok, true)
        let stats = await f.stats()
        XCTAssertEqual(stats.pullOk, 1)
        XCTAssertEqual(stats.pulled, 1)

        // a pull carries no `from`; known is stamped by the message ORIGIN only
        let known = await f.known()
        XCTAssertNotNil(known["hub"])
        XCTAssertNil(known["hub"]?.url, "a pull never learns an address for the peer it pulled")

        // one kick at the hub and the node is gone here on the next cycle
        await f.applyState(hubState(relayed: [:]), from: hub)
        let rebuilt = await f.relayed()
        XCTAssertTrue(rebuilt.isEmpty)
    }

    func testApplyStateGossipLearnsButNeverAdopts() async {
        let hub = Peer(name: "hub", url: "http://hub:6750")
        let f = fed(peers: [hub], gossip: true)
        await f.applyState(hubState(peers: [
            PeerView(name: "far", url: "http://far:6750"),
            PeerView(name: "alpha", url: "http://us:6750"),
            PeerView(name: "hub", url: "http://hub:6750"),
        ]), from: hub)

        let names = await f.peers().map(\.name)
        XCTAssertEqual(names, ["hub"], "gossip never adds a peer")
        let known = await f.known()
        XCTAssertEqual(known["far"]?.url, "http://far:6750")
        XCTAssertNil(known["alpha"])
        XCTAssertNil(known["hub"], "a direct peer is not 'heard of'")
    }

    func testGossipOffLearnsNothing() async {
        let hub = Peer(name: "hub", url: "http://hub:6750")
        let f = fed(peers: [hub])   // gossip nil
        await f.applyState(hubState(peers: [PeerView(name: "far", url: "http://far")]), from: hub)
        let known = await f.known()
        XCTAssertNil(known["far"])
    }

    func testLeaveDropsEverythingSeenThroughThatHub() async {
        let hub = Peer(name: "hub", url: "http://hub:6750")
        let other = Peer(name: "bravo", url: "http://bravo:6750")
        let f = fed(peers: [hub, other])
        await f.applyState(hubState(relayed: [
            "spoke": RelayedPeer(url: "http://spoke", members: [], ok: true, lastOkAt: nil, consecutive: 0),
        ]), from: hub)
        await f.applyState(hubState(node: "bravo", relayed: [
            "far": RelayedPeer(url: "http://far", members: [], ok: true, lastOkAt: nil, consecutive: 0),
        ]), from: other)
        let before = await f.relayed()
        XCTAssertEqual(Set(before.keys), ["spoke", "far"])

        await f.leave("hub")
        let names = await f.peers().map(\.name)
        XCTAssertEqual(names, ["bravo"])
        let after = await f.relayed()
        XCTAssertEqual(Set(after.keys), ["far"], "the hub's relayed nodes went with it")
        let rosters = await f.peerMembers()
        XCTAssertNil(rosters["hub"])
        let federated = await f.peerFederated()
        XCTAssertNil(federated["hub"])
        let kicks = await f.peerKicks()
        XCTAssertNil(kicks["hub"])
        let health = await f.health()
        XCTAssertNil(health["hub"])
    }

    func testLeaveAlsoDropsThatNodeAsARelayedEntry() async {
        let hub = Peer(name: "hub", url: "http://hub:6750")
        let f = fed(peers: [hub])
        await f.applyState(hubState(relayed: [
            "spoke": RelayedPeer(url: "http://spoke", members: [], ok: nil, lastOkAt: nil, consecutive: nil),
        ]), from: hub)
        await f.leave("spoke")   // a node we only ever saw through the hub
        let relayed = await f.relayed()
        XCTAssertTrue(relayed.isEmpty)
    }

    // MARK: - advertised

    func testAdvertisedRoundTrips() async {
        let f = fed()
        let none = await f.advertised()
        XCTAssertNil(none)
        await f.setAdvertised("http://10.0.0.5:6750")
        let some = await f.advertised()
        XCTAssertEqual(some, "http://10.0.0.5:6750")
    }
}

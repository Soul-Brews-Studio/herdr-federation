// Federation.swift — src/federation.ts, line for line.
//
// Our own message log and peer sync. No external hub.
//
// Transport is OUTBOUND-ONLY in both directions: a node pushes its own new
// messages to each peer and pulls each peer's new ones. A node therefore needs
// no inbound reachability at all, which matters because NetBird in userspace
// mode (macOS) blackholes inbound to the overlay IP while outbound works.
//
// The Bun file is the reference. Where this file looks odd, the oddity is
// ported on purpose — three of federation.ts's comments describe bugs that were
// measured on the fleet, and the rules that fixed them are kept verbatim:
// addPeer's "evidence beats a claim", #mark's merge, gossip that learns but
// never adopts.

import Foundation

/// What `String(err)` printed in the Bun node for a failed peer call — the text
/// that lands in `PeerHealth.lastError`, in a redeem.reject audit entry and in
/// `/api/peers/join`'s 400. Measured on Bun 1.3.14: a refused connection AND a
/// name that does not resolve both print `Error: Unable to connect. Is the
/// computer able to access the url?` (code ConnectionRefused); an
/// `AbortSignal.timeout` prints `TimeoutError: The operation timed out.`;
/// `await res.json()` on a body that is not JSON prints `SyntaxError: Failed to
/// parse JSON`. URLSession's own wording never reaches the wire. Other URLError
/// codes are unobserved and take the connect text.
func bunFetchError(_ error: Error) -> FederationError {
    if let f = error as? FederationError { return f }
    if let u = error as? URLError {
        if u.code == .timedOut { return FederationError("The operation timed out.", name: "TimeoutError") }
        return FederationError("Unable to connect. Is the computer able to access the url?")
    }
    if error is DecodingError { return FederationError("Failed to parse JSON", name: "SyntaxError") }
    return FederationError(error.localizedDescription)
}

/// One outbound HTTP call with a WALL-CLOCK deadline, the way
/// `fetch(url, { signal: AbortSignal.timeout(ms) })` behaves in the Bun node.
///
/// `URLRequest.timeoutInterval` is NOT that: it is an idle timer that every
/// arriving byte resets, and only `timeoutIntervalForResource` (7 days on
/// `URLSession.shared`, never set here) bounds the total. A peer that answers
/// its headers and then trickles one byte every 4 s therefore never tripped it —
/// the pull never finished, so `pullAll()` never returned, `sync()` never
/// returned, and the whole sync loop stopped ticking while `/api/status` went on
/// serving the stale health rows. AbortSignal aborts the whole fetch INCLUDING
/// `await res.text()`, so the deadline is raced against the call here.
///
/// `timeoutInterval` is left on the request as well: it is a cheaper first line
/// of defence for the ordinary dead-host case and cannot fire later than this.
func fetchWithDeadline(_ request: URLRequest, timeoutMs: Int) async throws -> (Data, URLResponse) {
    enum Leg: Sendable {
        case answered(Data, URLResponse)
        /// a VALUE, not a throw: the loser is cancelled and must not surface an
        /// error the task group would have to carry out of scope
        case deadline
    }
    return try await withThrowingTaskGroup(of: Leg.self) { group in
        group.addTask {
            let (data, response) = try await URLSession.shared.data(for: request)
            return .answered(data, response)
        }
        group.addTask {
            try? await Task.sleep(nanoseconds: UInt64(max(timeoutMs, 0)) * 1_000_000)
            return .deadline
        }
        defer { group.cancelAll() }
        switch try await group.next() {
        case .answered(let data, let response): return (data, response)
        // the exact text bunFetchError gives an AbortSignal.timeout
        case .deadline, .none: throw FederationError("The operation timed out.", name: "TimeoutError")
        }
    }
}

/// `String(err)` for whatever a push or pull threw.
private func errString(_ error: Error) -> String {
    if let h = error as? HerdrError { return h.description }
    if let n = error as? NodeError { return n.description }
    return bunFetchError(error).description
}

/// A `[String: V]` that remembers INSERTION order.
///
/// JS objects and Maps iterate in insertion order, and the Bun node turns three
/// of them into JSON ARRAYS — `Object.values(fed.known)` for `/api/status.known`
/// and `/api/admin.heard`, `Object.entries(fed.relayed)` for the relayed rows on
/// `/api/status.peers`, `Object.entries(fed.peerKicks)` feeding
/// `/api/admin.adoptable`. Array order survives parsing and is exactly what the
/// console renders, so a Swift Dictionary's per-process hash order is a real
/// divergence there, not a waived one.
struct OrderedMap<V: Sendable>: Sendable {
    private(set) var keys: [String] = []
    private var storage: [String: V] = [:]

    var dictionary: [String: V] { storage }
    var values: [V] { keys.compactMap { storage[$0] } }
    var entries: [(String, V)] { keys.compactMap { k in storage[k].map { (k, $0) } } }

    subscript(key: String) -> V? {
        get { storage[key] }
        set {
            if let newValue {
                if storage[key] == nil { keys.append(key) }
                storage[key] = newValue
            } else if storage.removeValue(forKey: key) != nil {
                keys.removeAll { $0 == key }
            }
        }
    }

    mutating func removeValue(forKey key: String) { self[key] = nil }
}

/// `.fed-state.json` — `JSON.stringify({ seq, messages })`: compact, last 500,
/// and that key order (JSONCoding writes members in declaration order).
struct SavedFedState: Codable, Sendable {
    var seq: Int?
    var messages: [FedMessage]?
}

public actor Federation: FederationSync {
    // MARK: stored state

    /// `readonly config` in Bun — the server holds the SAME object there and sees
    /// every peer edit. A Swift value type cannot alias, so callers must read
    /// `await config()` rather than keep a copy.
    private var configValue: FedConfig
    public nonisolated let statePath: String
    private let tokenFor: @Sendable (String) async -> String?
    nonisolated let timeoutMs: Int

    private var messageLog: [FedMessage] = []
    private var seenIds = Set<String>()
    private var seq = 0
    private var peerList: [Peer]

    /// Per-peer health, and the only honest answer to "is this link working NOW".
    ///
    /// `consecutive` is what a UI should read: lifetime totals cannot tell an
    /// outage an hour ago from one happening this second. Measured: m5 sat at
    /// `errors 1676` for an hour after white came back, beside a peer marked ok.
    private var healthMap: [String: PeerHealth] = [:]
    /// Nodes we have heard from but cannot reach back. A one-way link is normal
    /// here (userspace-mode NetBird), and the federation should still show them.
    private var knownMap = OrderedMap<KnownNode>()
    /// each peer's own roster, as that node reported it
    private var peerMembersMap: [String: [Member]] = [:]
    private var peerUiMap: [String: String] = [:]
    /// Nodes we hold no link to, seen through a hub we do hold. Keyed by node
    /// name; `via` is the hub. Never persisted, never republished, never synced
    /// with — a relayed node is something we can SEE, and can reach only by
    /// asking its hub to forward.
    private var relayedMap = OrderedMap<RelayedEntry>()
    /// Lifetime totals. `pushed` and `pullOk` count REQUESTS; `pulled` counts
    /// MESSAGES ingested, which is a different unit and is legitimately 0 whenever
    /// peers have nothing new.
    private var statsValue: Stats
    /// what each peer reports about its own membership — read-only, for the mesh view
    private var peerFederatedMap: [String: [MemberRecord]] = [:]
    /// kicks each peer published; adopting one is always a deliberate click here
    private var peerKicksMap = OrderedMap<[AuditEntry]>()
    /// How other nodes should reach us, when we know.
    private var advertisedURL: String?

    public nonisolated let node: String

    public init(
        config: FedConfig,
        statePath: String,
        tokenFor: @escaping @Sendable (String) async -> String? = { _ in nil },
        timeoutMs: Int = Const.peerTimeoutMs
    ) {
        self.configValue = config
        self.node = config.node
        self.statePath = statePath
        self.tokenFor = tokenFor
        self.timeoutMs = timeoutMs
        self.peerList = config.peers
        self.statsValue = Stats(startedAt: Stamp.iso())
    }

    // MARK: - getters (every one hands back a copy)

    /// `peers` is rewritten to `{name,url}` on every change — addPeer, join,
    /// leave — because the server writes exactly this to peers.json.
    public func config() -> FedConfig { configValue }
    public func peers() -> [Peer] { peerList }
    /// a direct peer by name, or nil — the test for "can we act on this node ourselves"
    public func peer(_ name: String) -> Peer? { peerList.first { $0.name == name } }
    public func health() -> [String: PeerHealth] { healthMap }
    public func known() -> [String: KnownNode] { knownMap.dictionary }
    public func peerMembers() -> [String: [Member]] { peerMembersMap }
    public func peerUi() -> [String: String] { peerUiMap }
    public func relayed() -> [String: RelayedEntry] { relayedMap.dictionary }
    public func peerFederated() -> [String: [MemberRecord]] { peerFederatedMap }
    public func peerKicks() -> [String: [AuditEntry]] { peerKicksMap.dictionary }
    /// `Object.values(fed.known)` — insertion order, the order nodes were first heard of.
    public func knownList() -> [KnownNode] { knownMap.values }
    /// `Object.entries(fed.relayed)` — insertion order, the order hubs first published them.
    public func relayedList() -> [(name: String, entry: RelayedEntry)] { relayedMap.entries.map { (name: $0.0, entry: $0.1) } }
    /// `Object.entries(fed.peerKicks)` — insertion order, the order peers first answered a pull.
    public func peerKicksList() -> [(from: String, entries: [AuditEntry])] { peerKicksMap.entries.map { (from: $0.0, entries: $0.1) } }
    public func stats() -> Stats { statsValue }
    public func messages() -> [FedMessage] { messageLog }
    public func advertised() -> String? { advertisedURL }
    public func setAdvertised(_ url: String?) { advertisedURL = url }

    private func syncConfigPeers() {
        configValue.peers = peerList.map { Peer(name: $0.name, url: $0.url) }
    }

    // MARK: - peers

    /// Register a peer we have just completed a handshake with.
    ///
    /// A node advertises ONE address, and that is not always the best one we have.
    /// m5 advertises its NetBird IP, but m5 runs NetBird in userspace mode, so
    /// inbound to that IP is blackholed — white can only reach m5 over the LAN.
    /// Taking the advertised address unconditionally therefore replaced white's
    /// working URL with an unreachable one and killed a link that was fine.
    /// So: an address we already have and that is currently healthy wins.
    public func addPeer(name: String, url: String) {
        if let i = peerList.firstIndex(where: { $0.name == name }) {
            // NEVER trade an address that has worked for one that merely claims to.
            //
            // Two earlier rules were both wrong. "replace unless currently ok" broke
            // right after a restart, when health is undefined. "replace when KNOWN
            // BAD" broke too, and worse: a link is known-bad for reasons that have
            // nothing to do with the address — m5 kicked white, so white's pulls 401'd,
            // so white took m5's advertised NetBird IP and replaced the LAN address
            // that had been working. Measured twice.
            //
            // An address that has ever completed a sync is evidence; an advertised one
            // is a claim. Evidence wins.
            let proven = healthMap[name]?.lastOkUrl
            // JS truthiness: `""` is falsy, so an empty proven url takes the claim.
            if peerList[i].url.isEmpty { peerList[i].url = url }
            else if proven == nil || proven!.isEmpty { peerList[i].url = url }
            else if peerList[i].url != proven! { peerList[i].url = proven! }
        } else {
            peerList.append(Peer(name: name, url: url))
        }
        syncConfigPeers()
    }

    /// Join a hub by address, the way you join a Discord server: probe it, learn
    /// its node name from its own mouth, and adopt it. Gossip then spreads the rest
    /// of the federation to us on the next pull.
    public func join(url: String) async throws -> JoinedNode {
        let clean = url
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "/+$", with: "", options: .regularExpression)
        guard let probe = URL(string: clean + "/api/fed/state") else {
            throw FederationError("\(clean) is not a federation node")
        }
        // A PLAIN request: no x-fed-token, no content-type — exactly what Bun sends.
        let reply = try await plainGet(probe)
        guard reply.ok else { throw FederationError("\(clean) answered \(reply.status)") }
        // `await res.json()` — a body that is not JSON is `SyntaxError: Failed to parse JSON`
        guard let body = try? JSONCoding.decode(JSONValue.self, from: reply.body) else {
            throw FederationError("Failed to parse JSON", name: "SyntaxError")
        }
        guard let name = body["node"]?.stringValue, !name.isEmpty else {
            throw FederationError("\(clean) is not a federation node")
        }
        guard name != node else { throw FederationError("that address is this node") }

        if let i = peerList.firstIndex(where: { $0.name == name }) {
            peerList[i].url = clean
        } else {
            peerList.append(Peer(name: name, url: clean))
        }
        syncConfigPeers()
        await pullAll()
        return JoinedNode(node: name, url: clean)
    }

    public func leave(_ name: String) {
        peerList.removeAll { $0.name == name }
        syncConfigPeers()
        peerMembersMap.removeValue(forKey: name)
        peerFederatedMap.removeValue(forKey: name)
        peerKicksMap.removeValue(forKey: name)
        healthMap.removeValue(forKey: name)
        // everything we saw through that hub went with it
        for (n, r) in relayedMap.entries where r.via == name { relayedMap.removeValue(forKey: n) }
        relayedMap.removeValue(forKey: name)
    }

    /// An authenticated call to a direct peer. Public so the server can forward on
    /// a spoke's behalf.
    public func call(_ name: String, path: String, method: String, body: Data?) async throws -> PeerReply {
        guard let p = peer(name) else {
            throw FederationError("\(name) is not a direct peer of \(node)")
        }
        return try await fetch(peerName: p.name, peerURL: p.url, path: path, method: method, body: body)
    }

    // MARK: - disk

    public func load() {
        guard let data = FileManager.default.contents(atPath: statePath),
              let saved = try? JSONCoding.decode(SavedFedState.self, from: data)
        else { return }  // first run
        messageLog = saved.messages ?? []
        seq = saved.seq ?? 0
        for m in messageLog { seenIds.insert(m.id) }
    }

    public func save() {
        let payload = SavedFedState(seq: seq, messages: Array(messageLog.suffix(Const.messagesCap)))
        guard let data = try? JSONCoding.encode(payload) else { return }
        try? data.write(to: URL(fileURLWithPath: statePath))
    }

    // MARK: - the log

    /// Record a message this node originated, and hand it to every peer.
    public func post(from: String, text: String) -> FedMessage {
        seq += 1
        let msg = FedMessage(id: "\(node):\(seq)", node: node, seq: seq, from: from, text: text, at: Stamp.iso())
        accept(msg)
        save()
        Task { await self.pushAll() }   // `void this.pushAll()` — fired, never awaited
        return msg
    }

    @discardableResult
    private func accept(_ msg: FedMessage) -> Bool {
        if seenIds.contains(msg.id) { return false }
        seenIds.insert(msg.id)
        messageLog.append(msg)
        messageLog = Array(messageLog.suffix(Const.messagesCap))
        return true
    }

    /// Messages a peer hands us. Exact dedup by origin id, so no echo storms.
    @discardableResult
    public func ingest(_ incoming: [FedMessage], from: IngestFrom?) -> Int {
        if let heard = from?.node, !heard.isEmpty, heard != node {
            knownMap[heard] = KnownNode(node: heard, url: from?.url, lastHeard: Stamp.iso())
        }
        var added = 0
        for m in incoming where !m.id.isEmpty {
            if accept(m) { added += 1 }
        }
        for m in incoming {
            if !m.node.isEmpty, m.node != node, knownMap[m.node] == nil {
                knownMap[m.node] = KnownNode(node: m.node, url: nil, lastHeard: Stamp.iso())
            }
        }
        if added > 0 { save() }
        return added
    }

    // MARK: - health

    /// Record one attempt. Merging matters: push and pull run in the same cycle, so
    /// assigning a whole record let whichever finished last erase the other's
    /// verdict — a link failing one way flapped green every other tick.
    func mark(_ peerName: String, ok: Bool, error: String? = nil) {
        let now = Stamp.iso()
        var h = healthMap[peerName] ?? PeerHealth(consecutive: 0)
        if ok {
            h.ok = true
            h.lastSeen = now
            h.lastOkAt = now
            h.consecutive = 0
            h.lastError = nil
            h.lastErrorAt = nil
            h.lastOkUrl = peerList.first { $0.name == peerName }?.url ?? h.lastOkUrl
        } else {
            h.ok = false
            h.lastError = error
            h.lastErrorAt = now
            h.consecutive += 1
        }
        healthMap[peerName] = h
    }

    // MARK: - transport

    /// One place stamps the credential, so no call site can forget to.
    nonisolated private func fetch(
        peerName: String,
        peerURL: String,
        path: String,
        method: String = "GET",
        body: Data? = nil,
        extraHeaders: [String: String] = [:]
    ) async throws -> PeerReply {
        let token = await tokenFor(peerName)
        guard let url = URL(string: peerURL + path) else {
            throw FederationError("Unable to connect. Is the computer able to access the url?")
        }
        var req = URLRequest(url: url, timeoutInterval: Double(timeoutMs) / 1000)
        req.httpMethod = method
        req.httpBody = body
        req.cachePolicy = .reloadIgnoringLocalCacheData
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        if let token { req.setValue(token, forHTTPHeaderField: "x-fed-token") }
        for (k, v) in extraHeaders { req.setValue(v, forHTTPHeaderField: k) }
        do {
            let (data, resp) = try await fetchWithDeadline(req, timeoutMs: timeoutMs)
            return PeerReply(status: (resp as? HTTPURLResponse)?.statusCode ?? 0, body: data)
        } catch {
            throw bunFetchError(error)
        }
    }

    /// `join`'s probe: no credential and no content-type, the way Bun sends it.
    nonisolated private func plainGet(_ url: URL) async throws -> PeerReply {
        var req = URLRequest(url: url, timeoutInterval: Double(timeoutMs) / 1000)
        req.httpMethod = "GET"
        req.cachePolicy = .reloadIgnoringLocalCacheData
        do {
            let (data, resp) = try await fetchWithDeadline(req, timeoutMs: timeoutMs)
            return PeerReply(status: (resp as? HTTPURLResponse)?.statusCode ?? 0, body: data)
        } catch {
            throw bunFetchError(error)
        }
    }

    // MARK: - sync

    public func pushAll() async {
        let mine = messageLog.filter { $0.node == node }
        if mine.isEmpty { return }
        // introduce ourselves, so a peer that cannot reach back still knows we exist
        let request = IngestRequest(
            messages: Array(mine.suffix(Const.pushBatch)),
            from: IngestFrom(node: node, url: advertisedURL)
        )
        guard let body = try? JSONCoding.encode(request) else { return }
        let targets = peerList
        await withTaskGroup(of: Void.self) { group in
            for target in targets {
                group.addTask {
                    do {
                        let res = try await self.fetch(
                            peerName: target.name, peerURL: target.url,
                            path: "/api/fed/ingest", method: "POST", body: body
                        )
                        guard res.ok else { throw FederationError("\(res.status)") }
                        await self.notePushOk(target.name, out: body.count, in: res.body.count)
                    } catch {
                        await self.notePushFail(target.name, error: errString(error))
                    }
                }
            }
        }
    }

    private func notePushOk(_ peerName: String, out: Int, in bytesIn: Int) {
        statsValue.pushed += 1
        statsValue.bytesOut += out
        statsValue.bytesIn += bytesIn
        mark(peerName, ok: true)
    }

    private func notePushFail(_ peerName: String, error: String) {
        statsValue.pushErrors += 1
        statsValue.errors += 1
        mark(peerName, ok: false, error: error)
    }

    /// Pull is what makes an unreachable node still work: we fetch, it never has to reach us.
    public func pullAll() async {
        let targets = peerList
        await withTaskGroup(of: Void.self) { group in
            for target in targets {
                group.addTask {
                    do {
                        let res = try await self.fetch(
                            peerName: target.name, peerURL: target.url, path: "/api/fed/state"
                        )
                        guard res.ok else { throw FederationError("\(res.status)") }
                        // bytes first, so the count is what actually crossed the wire
                        await self.noteBytesIn(res.body.count)
                        // `JSON.parse(raw)` — JavaScriptCore's detail ("Unexpected identifier …") is not reproduced
                        guard let state = try? JSONCoding.decode(FedState.self, from: res.body) else {
                            throw FederationError("JSON Parse error", name: "SyntaxError")
                        }
                        await self.applyState(state, from: target)
                    } catch {
                        await self.notePullFail(target.name, error: errString(error))
                    }
                }
            }
        }
    }

    private func noteBytesIn(_ n: Int) { statsValue.bytesIn += n }

    private func notePullFail(_ peerName: String, error: String) {
        statsValue.pullErrors += 1
        statsValue.errors += 1
        mark(peerName, ok: false, error: error)
    }

    /// Everything a successful pull does with the body, with no transport in it —
    /// the ingest, the rosters, the hub rebuild and the gossip.
    func applyState(_ state: FedState, from target: Peer) {
        // NO `from` — a pull does not stamp known[peer]; only a push introduces.
        let added = ingest(state.messages, from: nil)
        statsValue.pullOk += 1
        statsValue.pulled += added
        peerMembersMap[target.name] = state.members
        peerFederatedMap[target.name] = state.federated ?? []
        peerKicksMap[target.name] = state.kicks ?? []
        peerUiMap[target.name] = target.url
        mark(target.name, ok: true)

        // The hub model. What this peer holds directly, we now see through it.
        // Rebuilt from scratch per pull so a node the hub kicked vanishes here
        // on the next cycle — one kick at the hub, gone everywhere, with no
        // "adopt" step. A direct link always wins over a relayed one, and we
        // never relay ourselves back to ourselves.
        for (n, r) in relayedMap.entries where r.via == target.name { relayedMap.removeValue(forKey: n) }
        // A peer's `relayed` object arrives as a Swift Dictionary, which has
        // already thrown away the JSON key order Bun would have iterated. Sorted
        // is not Bun's order either, but it is DETERMINISTIC — the same pull
        // produces the same order twice — where hash order is not. Names already
        // held keep their original slot; only the new ones land here.
        for (n, r) in (state.relayed ?? [:]).sorted(by: { $0.key < $1.key }) {
            if n == node || peerList.contains(where: { $0.name == n }) { continue }
            relayedMap[n] = RelayedEntry(
                via: target.name, url: r.url, members: r.members,
                ok: r.ok, lastOkAt: r.lastOkAt, consecutive: r.consecutive
            )
        }

        // Gossip LEARNS OF nodes; it no longer adopts them.
        //
        // Adopting predates membership and is now actively wrong. A peer we hold
        // no token for cannot be synced with — every push and pull to it 401s or
        // times out — so adoption only manufactures failing requests every cycle.
        // Worse, it silently undoes a kick: measured on a six-node demo, a kicked
        // node was back in the in-memory peer list within one cycle.
        //
        // `known` is exactly the right home for "we have heard of this node": the
        // console renders it as "heard from, not joined" with a join button, which
        // is the deliberate act adoption was pretending to be.
        if configValue.gossip == true {
            for cand in state.peers {
                if cand.name == node { continue }
                if peerList.contains(where: { $0.name == cand.name }) { continue }
                knownMap[cand.name] = KnownNode(node: cand.name, url: cand.url, lastHeard: Stamp.iso())
            }
        }
    }
}

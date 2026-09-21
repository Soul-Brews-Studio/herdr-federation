// Runtime.swift — everything in src/server.ts that is not a route handler.
//
// The Bun node keeps this state in module-level `let`s and closures: the roster
// cache `members`, the `topology` beside it, `saveConfig()`, `invite()`,
// `member()`, `deliverLocal()`, the four relay views, and `sync()`. One object
// holds them here so Routes.swift and PaneStream.swift share exactly one copy,
// the way the module scope did.
//
// Parity notes are inline and marked `BUN:`. Nothing here "fixes" the Bun
// behaviour — where the two could differ, the Bun node wins.

import Foundation
import HTTPTypes
import Hummingbird

public final class NodeRuntime: @unchecked Sendable {
    public let env: NodeEnv
    /// `config` — the parsed peers.json, exactly as server.ts holds it
    public let config: FedConfig
    public let ident: NodeIdentity
    /// `fedMembers` in server.ts — the membership store, NOT the roster
    public let fedMembers: any MembersStore
    public let fed: any FederationSync
    public let herdr: any HerdrClient
    public let nudger: any PaneNudger
    public let log: AccessLog

    private let lock = NSLock()
    private var _members: [Member] = []
    private var _topology = Topology()
    /// keys peers.json held that `FedConfig` does not model — `{...config}` in
    /// saveConfig() spreads them back out, so a rewrite must not eat them
    private let configExtras: [String: JSONValue]
    /// the order peers.json listed its keys in — see ConfigDocument.encode
    private let configKeyOrder: [String]

    public init(
        env: NodeEnv,
        config: FedConfig,
        ident: NodeIdentity,
        members: any MembersStore,
        fed: any FederationSync,
        herdr: any HerdrClient,
        nudger: any PaneNudger,
        log: AccessLog
    ) {
        self.env = env
        self.config = config
        self.ident = ident
        self.fedMembers = members
        self.fed = fed
        self.herdr = herdr
        self.nudger = nudger
        self.log = log

        // Read once at boot, like the Bun node's top-level
        // `await Bun.file(CONFIG_PATH).json()`: a later edit to peers.json is NOT
        // picked up by a save, on either runtime.
        var extras: [String: JSONValue] = [:]
        if let data = FileManager.default.contents(atPath: env.configPath),
           let parsed = try? JSONCoding.decode(JSONValue.self, from: data),
           let object = parsed.objectValue {
            for (k, v) in object where k != "node" && k != "gossip" && k != "peers" { extras[k] = v }
        }
        self.configExtras = extras
        // JSONDecoder hands back a Dictionary, which has already lost the key
        // order, so it is read off the raw bytes.
        self.configKeyOrder = (FileManager.default.contents(atPath: env.configPath)).map(jsonTopLevelKeyOrder) ?? []
    }

    // MARK: - the roster cache

    /// `members` in server.ts — the panes herdr reported on the last refresh.
    public var members: [Member] { lock.withLock { _members } }
    /// `topology` in server.ts — workspaces and tabs, so the console can show
    /// what herdr itself shows.
    public var topology: Topology { lock.withLock { _topology } }

    /// `refreshMembers()`. BUN: every failure collapses to `members = []` and
    /// leaves `topology` at its last value — a herdr that went away empties the
    /// roster but keeps drawing the workspaces.
    public func refreshMembers() async {
        do {
            let snap = try await herdr.snapshot()

            var topo = Topology()
            topo.workspaces = snap.workspaces.map { w in
                var u = UiWorkspace(id: w.workspace_id)
                u.label = w.label
                u.number = w.number
                u.status = w.agent_status
                u.paneCount = w.pane_count
                u.repo = w.worktree?.repo_name
                u.checkout = w.worktree?.checkout_path
                u.linkedWorktree = w.worktree?.is_linked_worktree
                return u
            }
            topo.tabs = snap.tabs.map { t in
                var u = UiTab(id: t.tab_id, workspace: t.workspace_id)
                u.label = t.label
                u.number = t.number
                u.status = t.agent_status
                u.paneCount = t.pane_count
                return u
            }

            // `new Map(workspaces.map(w => [w.workspace_id, w]))` — last one wins
            var byId: [String: HerdrWorkspace] = [:]
            for w in snap.workspaces { byId[w.workspace_id] = w }

            let roster: [Member] = snap.panes.map { p in
                let ws = p.workspace_id.flatMap { byId[$0] }
                var m = Member(
                    handle: p.agent_name ?? p.label ?? p.terminal_title_stripped ?? p.pane_id,
                    kind: p.agent ?? "shell",
                    pane: p.pane_id
                )
                m.`where` = p.cwd
                m.status = p.agent_status
                m.terminal = p.terminal_id
                m.focused = p.focused
                m.revision = p.revision
                m.scrollback = p.scroll?.max_offset_from_bottom
                m.rows = p.scroll?.viewport_rows
                m.tab = p.tab_id
                m.workspace = p.workspace_id
                m.workspaceLabel = ws?.label
                m.repo = ws?.worktree?.repo_name
                return m
            }

            lock.withLock {
                _topology = topo
                _members = roster
            }
        } catch {
            lock.withLock { _members = [] }
        }
    }

    // MARK: - peers.json

    private struct PeerRef: Encodable {
        var name: String
        var url: String
    }

    /// `{ ...config, peers: fed.peers.map(({name, url}) => ({name, url})) }`,
    /// pretty-printed. BUN: only `name` and `url` survive — a peer's `via` is
    /// dropped on every save, which is how a relayed node never becomes
    /// configuration.
    private struct ConfigDocument: Encodable {
        var node: String
        var gossip: Bool?
        var extras: [String: JSONValue]
        /// the key order peers.json had on disk, so a rewrite touches only what
        /// changed. `{ ...config, peers: ... }` in JS keeps every key's original
        /// position and OVERWRITES `peers` in place, so sorting the extras and
        /// moving `peers` to the end churned every line of the file.
        var order: [String]
        var peers: [PeerRef]

        struct Key: CodingKey {
            var stringValue: String
            var intValue: Int? { nil }
            init(_ s: String) { stringValue = s }
            init?(stringValue s: String) { stringValue = s }
            init?(intValue: Int) { nil }
        }

        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: Key.self)
            var written = Set<String>()
            func write(_ k: String) throws {
                guard written.insert(k).inserted else { return }
                switch k {
                case "node": try c.encode(node, forKey: Key("node"))
                case "gossip": if let gossip { try c.encode(gossip, forKey: Key("gossip")) }
                case "peers": try c.encode(peers, forKey: Key("peers"))
                default: if let v = extras[k] { try c.encode(v, forKey: Key(k)) }
                }
            }
            for k in order { try write(k) }
            // keys the file did not have: JS appends a new key at the end, and
            // `{ ...config, peers }` always materialises `peers`.
            try write("node")
            try write("gossip")
            for k in extras.keys.sorted() { try write(k) }
            try write("peers")
        }
    }

    public func saveConfig() async {
        let refs = await fed.peers().map { PeerRef(name: $0.name, url: $0.url) }
        let doc = ConfigDocument(node: config.node, gossip: config.gossip, extras: configExtras, order: configKeyOrder, peers: refs)
        guard let data = try? JSONCoding.encode(doc, pretty: true) else { return }
        try? data.write(to: URL(fileURLWithPath: env.configPath))
    }

    // MARK: - invites and identity

    /// `invite()` — what to hand someone so they can join this node.
    public func invite() -> Invite {
        let base = env.publicBase()
        return Invite(
            node: config.node,
            session: env.herdrSession,
            socket: herdr.socketPath,
            url: base,
            hint: base != nil
                ? nil
                : "set FED_ADVERTISE to the address peers should use, or this node cannot issue a working invite"
        )
    }

    /// `member(req)` — the federation gate. BUN: while FED_ALLOW_LEGACY is on,
    /// ANY caller passes, named "(legacy, unverified)". That is the whole
    /// legacy tolerance, and it is on by default.
    public func member(token: String?) async -> (ok: Bool, node: String) {
        if let found = await fedMembers.authenticate(token: token) { return (true, found.node) }
        if env.allowLegacy { return (true, "(legacy, unverified)") }
        return (false, "")
    }

    public func member(_ request: Request) async -> (ok: Bool, node: String) {
        await member(token: HTTPField.Name("x-fed-token").flatMap { request.headers[$0] })
    }

    // MARK: - local delivery

    /// `deliverLocal()` — the one local delivery path, by pane id or handle.
    @discardableResult
    public func deliverLocal(_ to: String, _ text: String) async throws -> Member {
        guard let target = members.first(where: { $0.pane == to || $0.handle == to }) else {
            throw NodeError("no agent \(to) on \(config.node)")
        }
        try await herdr.prompt(target.pane, text)
        await nudger.nudge(target.pane)
        return target
    }

    // MARK: - relay views

    /// `relayedFor(except)`. BUN: a peer with no `lastOkAt` is skipped, so a
    /// link we have never completed relays nothing rather than a ghost row.
    public func relayedFor(_ except: String) async -> [String: RelayedPeer] {
        let health = await fed.health()
        let rosters = await fed.peerMembers()
        var out: [String: RelayedPeer] = [:]
        for p in await fed.peers() {
            if p.name == except || p.name == config.node { continue }
            guard let h = health[p.name], let lastOkAt = h.lastOkAt, !lastOkAt.isEmpty else { continue }
            out[p.name] = RelayedPeer(
                url: p.url,
                members: rosters[p.name] ?? [],
                ok: h.ok,
                lastOkAt: h.lastOkAt,
                consecutive: h.consecutive
            )
        }
        return out
    }

    /// `allPeerMembers()` — direct rosters, then relayed ones for names we do
    /// not already hold.
    public func allPeerMembers() async -> [String: [Member]] {
        var out = await fed.peerMembers()
        for (name, r) in await fed.relayed() where out[name] == nil { out[name] = r.members }
        return out
    }

    /// `allPeerUi()` — where to send an action for a node: itself if direct,
    /// its hub if relayed. BUN: the `fed.peerUi[r.via]` lookup reads the
    /// ORIGINAL map, not the one being built, so a hub that is itself only
    /// relayed resolves through `fed.peer(via)?.url` or falls to "".
    public func allPeerUi() async -> [String: String] {
        let direct = await fed.peerUi()
        var out = direct
        for (name, r) in await fed.relayed() where out[name] == nil {
            if let hub = direct[r.via] {
                out[name] = hub
            } else {
                out[name] = (await fed.peer(r.via))?.url ?? ""
            }
        }
        return out
    }

    /// `relayedViews()` — relayed nodes as PeerView rows.
    ///
    /// `Object.entries(fed.relayed).map(...)` — an ARRAY, so the order is on the
    /// wire and is what the console draws. Insertion order, not hash order.
    public func relayedViews() async -> [PeerView] {
        let direct = await fed.peerUi()
        var rows: [PeerView] = []
        for (name, r) in await fed.relayedList() {
            let url: String
            if let hub = direct[r.via] { url = hub } else { url = (await fed.peer(r.via))?.url ?? "" }
            var v = PeerView(name: name, url: url)
            v.via = r.via
            v.ok = r.ok
            v.lastOkAt = r.lastOkAt
            v.consecutive = r.consecutive ?? 0
            rows.append(v)
        }
        return rows
    }

    // MARK: - the sync tick

    /// `sync()` — roster first, then pull, then push. The order is server.ts's:
    /// a push carries what the pull just taught us.
    public func sync() async {
        await refreshMembers()
        await fed.pullAll()
        await fed.pushAll()
    }
}

/// The key order of a JSON document's TOP level, read straight off the bytes.
///
/// `JSONDecoder` hands back a Swift Dictionary and a Dictionary has no order, so
/// this is the only way to know what peers.json listed first. Used by
/// `saveConfig()` to rewrite the file in the order JS's `{ ...config }` spread
/// would have kept. Strings are unescaped by the real decoder, never by hand.
func jsonTopLevelKeyOrder(_ data: Data) -> [String] {
    let bytes = [UInt8](data)
    let quote = UInt8(ascii: "\"")
    let backslash = UInt8(ascii: "\\")
    var keys: [String] = []
    var depth = 0
    var i = 0
    while i < bytes.count {
        switch bytes[i] {
        case UInt8(ascii: "{"), UInt8(ascii: "["):
            depth += 1
            i += 1
        case UInt8(ascii: "}"), UInt8(ascii: "]"):
            depth -= 1
            i += 1
        case quote:
            var j = i + 1
            var raw: [UInt8] = []
            while j < bytes.count {
                if bytes[j] == backslash, j + 1 < bytes.count {
                    raw.append(bytes[j]); raw.append(bytes[j + 1])
                    j += 2
                    continue
                }
                if bytes[j] == quote { break }
                raw.append(bytes[j])
                j += 1
            }
            var k = j + 1
            while k < bytes.count, bytes[k] == 0x20 || bytes[k] == 0x09 || bytes[k] == 0x0a || bytes[k] == 0x0d { k += 1 }
            if depth == 1, k < bytes.count, bytes[k] == UInt8(ascii: ":"),
               let key = try? JSONCoding.decode(String.self, from: Data([quote] + raw + [quote])) {
                keys.append(key)
            }
            i = j + 1
        default:
            i += 1
        }
    }
    return keys
}

// Contract.swift — the seam every module codes against, and nothing else.
//
// Mirrors src/wire.ts and src/protocol.ts FIELD FOR FIELD, including which keys
// are omitted (Swift `Optional` → `encodeIfPresent`) versus which are sent as an
// explicit JSON null (`@NullIfNil`). Every constant is lifted from the Bun file it
// names. If a shape here and the Bun wire disagree, the Bun wire is right — fix
// this file, not the module that consumed it.
//
// wire.ts stays the source of truth for the fleet. This file is its Swift mirror.

import Foundation

// MARK: - Constants

/// Every magic number in the Bun node, with the file it came from.
public enum Const {
    // server.ts
    public static let defaultPort = 6750
    public static let defaultHost = "127.0.0.1"
    public static let syncMs = 2000            // FED_SYNC_MS
    public static let paneMs = 300             // FED_PANE_MS
    public static let wsIdleTimeoutSeconds = 120
    public static let portProbeMs = 700        // the port guard's fetch timeout
    public static let redeemTimeoutMs = 8000   // POST /api/peers/redeem → peer
    public static let statusMessages = 60      // /api/status returns the last 60, newest first
    public static let adminAuditLimit = 200    // /api/admin audit slice
    public static let auditDefaultLimit = 100  // /api/audit?limit default
    public static let callsDefaultLimit = 80   // /api/calls?limit default
    public static let paneLinesDefault = 40    // /api/fed/pane, /api/fleet/pane
    public static let paneLinesMin = 1
    public static let paneLinesMax = 400
    public static let paneStreamLines = 200    // /ws/pane and /api/pane default
    /// `/^[A-Za-z0-9_:-]+$/` — anything else is not a pane id we will open
    public static let paneIdPattern = "^[A-Za-z0-9_:-]+$"

    // herdr.ts
    public static let herdrTimeoutMs = 5000
    public static let herdrIsUpTimeoutMs = 1500
    public static let herdrMaxLineBytes = 1024 * 1024
    public static let callsCap = 200
    public static let herdrDefaultLines = 200
    public static let herdrDefaultSource = "visible"
    public static let herdrDefaultFormat = "text"

    // federation.ts
    public static let peerTimeoutMs = 5000
    public static let messagesCap = 500        // in memory and on disk
    public static let pushBatch = 100          // a push carries the last 100 of OUR messages

    // members.ts
    public static let auditCap = 500
    public static let publishedKicksCap = 50
    public static let signatureWindowMs = 5 * 60 * 1000
    public static let inviteDefaultHours = 24

    // identity.ts
    public static let secretBytes = 24         // base64url → 32 chars
    public static let fingerprintChars = 16
}

// MARK: - Clock and ids (the Bun node's Date/Math.random idioms)

public enum Stamp {
    /// `new Date().toISOString()` — millisecond precision, always `Z`.
    public static func iso(_ date: Date = Date()) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSS'Z'"
        return f.string(from: date)
    }

    /// `new Date().toTimeString().slice(0, 8)` — local wall clock, for the access log.
    public static func hms(_ date: Date = Date()) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "HH:mm:ss"
        return f.string(from: date)
    }

    /// `Date.parse(s)` for the ISO strings this node and its peers write. `nil`
    /// where JS would give NaN.
    public static func parse(_ s: String) -> Date? {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = iso.date(from: s) { return d }
        iso.formatOptions = [.withInternetDateTime]
        return iso.date(from: s)
    }

    /// `Date.now()` in milliseconds.
    public static func nowMs() -> Int64 { Int64(Date().timeIntervalSince1970 * 1000) }
}

/// `Math.random().toString(36).slice(2, 10)` — an 8-char base36 id.
public func randomId() -> String {
    let alphabet = Array("0123456789abcdefghijklmnopqrstuvwxyz")
    return String((0..<8).map { _ in alphabet[Int.random(in: 0..<36)] })
}

// MARK: - JSON helpers

/// A JSON value we pass through untouched — `Record<string, unknown>` in the Bun code.
public enum JSONValue: Codable, Equatable, Sendable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case null
    case array([JSONValue])
    case object([String: JSONValue])

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let b = try? c.decode(Bool.self) { self = .bool(b) }
        else if let n = try? c.decode(Double.self) { self = .number(n) }
        else if let s = try? c.decode(String.self) { self = .string(s) }
        else if let a = try? c.decode([JSONValue].self) { self = .array(a) }
        else if let o = try? c.decode([String: JSONValue].self) { self = .object(o) }
        else { throw DecodingError.dataCorruptedError(in: c, debugDescription: "not JSON") }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .string(let s): try c.encode(s)
        case .number(let n):
            // JS prints 5 as `5`, never `5.0`
            if n == n.rounded(), abs(n) < 1e15 { try c.encode(Int64(n)) } else { try c.encode(n) }
        case .bool(let b): try c.encode(b)
        case .null: try c.encodeNil()
        case .array(let a): try c.encode(a)
        case .object(let o): try c.encode(o)
        }
    }

    public subscript(key: String) -> JSONValue? {
        if case .object(let o) = self { return o[key] }
        return nil
    }
    public var stringValue: String? { if case .string(let s) = self { return s }; return nil }
    public var intValue: Int? { if case .number(let n) = self { return Int(n) }; return nil }
    public var boolValue: Bool? { if case .bool(let b) = self { return b }; return nil }
    public var arrayValue: [JSONValue]? { if case .array(let a) = self { return a }; return nil }
    public var objectValue: [String: JSONValue]? { if case .object(let o) = self { return o }; return nil }
}

/// Encode `nil` as an explicit JSON `null` instead of omitting the key — for the
/// fields wire.ts types as `string | null` rather than `string?`. Decoding a
/// missing key yields `nil`, the same as JS reading an absent property.
@propertyWrapper
public struct NullIfNil<T: Codable & Sendable>: Codable, Sendable {
    public var wrappedValue: T?
    public init(wrappedValue: T?) { self.wrappedValue = wrappedValue }
    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        wrappedValue = c.decodeNil() ? nil : try c.decode(T.self)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        if let v = wrappedValue { try c.encode(v) } else { try c.encodeNil() }
    }
}

extension NullIfNil: Equatable where T: Equatable {}

extension KeyedDecodingContainer {
    /// A missing key decodes as `nil`, so `@NullIfNil` never fails on absence.
    public func decode<T>(_ type: NullIfNil<T>.Type, forKey key: Key) throws -> NullIfNil<T> {
        try decodeIfPresent(type, forKey: key) ?? NullIfNil(wrappedValue: nil)
    }
}

/// Three-way JSON presence: the key was absent, the key was `null`, or it held a
/// value. Needed where the Bun code destructures with a default —
/// `{ hours = 24 }` applies 24 only to `undefined`, and `null` means "never".
public enum Nullable<T: Codable & Sendable>: Codable, Sendable {
    case absent
    case null
    case value(T)

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        self = c.decodeNil() ? .null : .value(try c.decode(T.self))
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .absent, .null: try c.encodeNil()
        case .value(let v): try c.encode(v)
        }
    }
    public var value: T? { if case .value(let v) = self { return v }; return nil }
}

extension Nullable: Equatable where T: Equatable {}

extension KeyedDecodingContainer {
    /// `decodeIfPresent` would fold an explicit null into "absent"; the whole
    /// point of `Nullable` is to keep them apart.
    public func decode<T>(_ type: Nullable<T>.Type, forKey key: Key) throws -> Nullable<T> {
        guard contains(key) else { return .absent }
        if try decodeNil(forKey: key) { return .null }
        return .value(try decode(T.self, forKey: key))
    }
}

/// One encoder / decoder configuration for every wire and disk write.
///
/// Encoding is `JSONStringify`, not Foundation's JSONEncoder: members come out in
/// declaration order, slashes are not escaped, numbers print as JavaScript
/// prints them, and `pretty` is exactly `JSON.stringify(x, null, 2)`. For a
/// struct that is byte for byte what the Bun node writes. The one thing that
/// still differs is a `[String: …]` member — a Swift Dictionary has no insertion
/// order, and JSONDecoder returns Dictionaries, so `Record<string, …>` fields
/// (peerMembers, peerUi, relayed, meshMembers, peerPanes, a call's params) keep
/// a random member order. A conformance check must compare those parsed.
public enum JSONCoding {
    public static let decoder = JSONDecoder()

    public static func encode<T: Encodable>(_ v: T, pretty: Bool = false) throws -> Data {
        try JSONStringify.data(v, pretty: pretty)
    }
    public static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        try decoder.decode(type, from: data)
    }
}

extension KeyedDecodingContainer {
    /// Decode an array ELEMENT BY ELEMENT, dropping the ones that will not
    /// parse. The Bun node never validates these: federation.ts does one
    /// `JSON.parse(raw)` into a loose cast and then reads `state.messages ?? []`,
    /// `state.members ?? []`, `state.federated ?? []`. A peer that omits one
    /// field of one row must therefore cost that row, not the whole pull — a
    /// strict container decode turned that into a permanent `SyntaxError: JSON
    /// Parse error` on the link, with the roster, kicks and messages all
    /// discarded, where Bun absorbed the body.
    ///
    /// Returns nil only when the key itself is missing or is not an array.
    public func decodeLenientArrayIfPresent<T: Decodable>(_ type: T.Type, forKey key: Key) -> [T]? {
        guard let raw = try? decodeIfPresent([JSONValue].self, forKey: key) else { return nil }
        return raw.compactMap { element in
            guard let data = try? JSONCoding.encode(element) else { return nil }
            return try? JSONCoding.decode(T.self, from: data)
        }
    }

    /// The `Record<string, …>` counterpart: keep the entries that parse.
    public func decodeLenientDictionaryIfPresent<T: Decodable>(_ type: T.Type, forKey key: Key) -> [String: T]? {
        guard let raw = try? decodeIfPresent([String: JSONValue].self, forKey: key) else { return nil }
        var out: [String: T] = [:]
        for (k, v) in raw {
            guard let data = try? JSONCoding.encode(v), let decoded = try? JSONCoding.decode(T.self, from: data) else { continue }
            out[k] = decoded
        }
        return out
    }
}

// MARK: - protocol.ts — what the herdr socket returns (protocol 22)

/// `"idle" | "working" | "blocked" | "done" | "unknown"` — kept as String so a
/// newer herdr cannot break a decode.
public typealias AgentStatus = String

public struct HerdrWorktree: Codable, Sendable, Equatable {
    public var repo_key: String?
    public var repo_name: String?
    public var repo_root: String?
    public var checkout_path: String?
    public var is_linked_worktree: Bool?
    public init() {}
}

public struct HerdrWorkspace: Codable, Sendable, Equatable {
    public var workspace_id: String
    public var number: Int?
    public var label: String?
    public var focused: Bool?
    public var pane_count: Int?
    public var tab_count: Int?
    public var active_tab_id: String?
    public var agent_status: AgentStatus?
    public var worktree: HerdrWorktree?
    public init(workspace_id: String) { self.workspace_id = workspace_id }
}

public struct HerdrTab: Codable, Sendable, Equatable {
    public var tab_id: String
    public var workspace_id: String
    public var number: Int?
    public var label: String?
    public var focused: Bool?
    public var pane_count: Int?
    public var agent_status: AgentStatus?
    public init(tab_id: String, workspace_id: String) { self.tab_id = tab_id; self.workspace_id = workspace_id }
}

public struct HerdrScroll: Codable, Sendable, Equatable {
    public var offset_from_bottom: Int?
    public var max_offset_from_bottom: Int?
    public var viewport_rows: Int?
    public init() {}
}

/// A pane. `Agent` in protocol.ts is `Pane & { agent: string }` — the same shape.
public struct HerdrPane: Codable, Sendable, Equatable {
    public var pane_id: String
    public var terminal_id: String?
    public var workspace_id: String?
    public var tab_id: String?
    public var focused: Bool?
    public var cwd: String?
    public var foreground_cwd: String?
    public var agent: String?
    /// `string | null` on the wire; nil either way here
    public var agent_name: String?
    public var label: String?
    public var terminal_title: String?
    public var terminal_title_stripped: String?
    public var agent_status: AgentStatus?
    public var scroll: HerdrScroll?
    public var revision: Int?
    public init(pane_id: String) { self.pane_id = pane_id }
}

public struct HerdrSnapshot: Codable, Sendable, Equatable {
    /// protocol.ts declares `version?: number`, and that is wrong: herdr 0.9.1
    /// (protocol 22) sends `"version":"0.9.1"`, a STRING. Bun casts the parsed
    /// JSON instead of decoding it, so five live nodes never noticed; a Swift
    /// decode typed `Int?` threw `typeMismatch` on every snapshot. Any other
    /// type in this slot is dropped rather than failing the snapshot — the
    /// closest thing to a cast that never looked.
    public var version: String?
    public var protocolVersion: Int?
    public var focused_workspace_id: String?
    public var focused_tab_id: String?
    public var focused_pane_id: String?
    public var workspaces: [HerdrWorkspace]
    public var tabs: [HerdrTab]
    public var panes: [HerdrPane]
    public var agents: [HerdrPane]

    enum CodingKeys: String, CodingKey {
        case version
        case protocolVersion = "protocol"
        case focused_workspace_id, focused_tab_id, focused_pane_id, workspaces, tabs, panes, agents
    }

    public init(workspaces: [HerdrWorkspace] = [], tabs: [HerdrTab] = [], panes: [HerdrPane] = [], agents: [HerdrPane] = []) {
        self.workspaces = workspaces; self.tabs = tabs; self.panes = panes; self.agents = agents
    }

    /// Every array is optional on the wire (`snap.panes ?? []` in server.ts).
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = (try? c.decodeIfPresent(String.self, forKey: .version)) ?? nil
        protocolVersion = try c.decodeIfPresent(Int.self, forKey: .protocolVersion)
        focused_workspace_id = try c.decodeIfPresent(String.self, forKey: .focused_workspace_id)
        focused_tab_id = try c.decodeIfPresent(String.self, forKey: .focused_tab_id)
        focused_pane_id = try c.decodeIfPresent(String.self, forKey: .focused_pane_id)
        workspaces = try c.decodeIfPresent([HerdrWorkspace].self, forKey: .workspaces) ?? []
        tabs = try c.decodeIfPresent([HerdrTab].self, forKey: .tabs) ?? []
        panes = try c.decodeIfPresent([HerdrPane].self, forKey: .panes) ?? []
        agents = try c.decodeIfPresent([HerdrPane].self, forKey: .agents) ?? []
    }
}

/// `pane.read` — a `visible` read carries revision 0; diff on the text.
///
/// protocol.ts types `source`, `format` and `text` as required, but server.ts
/// reads `read.text ?? ""` and `String(read?.text ?? "")` — a reply without
/// `text` is an empty frame there, never a failure. Optional here for the same
/// reason; `source` and `format` are never read by the node at all. herdr 0.9.1
/// sends all three on every reply (verified live).
public struct HerdrPaneRead: Codable, Sendable, Equatable {
    public var pane_id: String
    public var workspace_id: String?
    public var tab_id: String?
    public var source: String?
    public var format: String?
    public var text: String?
    public var revision: Int?
    public var truncated: Bool?
    public init(pane_id: String, source: String?, format: String?, text: String?) {
        self.pane_id = pane_id; self.source = source; self.format = format; self.text = text
    }
}

public struct HerdrSocketError: Codable, Sendable, Equatable {
    public var code: String?
    public var message: String?
}

/// `HerdrError` in herdr.ts: `code` ∈ request_too_large · timeout · bad_response ·
/// socket · closed · or the code the server sent. `description` is what
/// `String(err)` printed in Bun: "Error: <message>".
public struct HerdrError: Error, CustomStringConvertible, Sendable, Equatable {
    public var code: String
    public var message: String
    public init(code: String, message: String) { self.code = code; self.message = message }
    public var description: String { "Error: \(message)" }
}

// MARK: - herdr.ts — the socket client

/// One socket transaction, with its CLI equivalent. `GET /api/calls`.
public struct CallRecord: Codable, Sendable, Equatable {
    public var at: String
    public var method: String
    public var params: [String: JSONValue]
    @NullIfNil public var cli: String?
    public var ms: Int
    public var ok: Bool
    public var error: String?
    public init(at: String, method: String, params: [String: JSONValue], cli: String?, ms: Int, ok: Bool, error: String? = nil) {
        self.at = at; self.method = method; self.params = params; self.cli = cli; self.ms = ms; self.ok = ok; self.error = error
    }
}

/// The seven RPCs the node makes, the transport rules in herdr.ts's header, and
/// the call log. Every call opens its own connection; the server closes after one
/// reply; a request line is capped at 1 MiB.
public protocol HerdrClient: AnyObject, Sendable {
    var socketPath: String { get }

    /// Raw RPC. `params` is the JSON object sent as `params`; the result is the
    /// `result` object of the reply. Throws `HerdrError`.
    func call(_ method: String, params: [String: JSONValue], timeoutMs: Int) async throws -> JSONValue

    /// `session.snapshot`, falling back to `workspace.list` + `pane.list`
    /// (tabs and agents empty) when the server predates it.
    func snapshot() async throws -> HerdrSnapshot
    func agents() async throws -> [HerdrPane]
    /// `pane.read` with `source` defaulting to `visible`, `lines` 200, `format` text.
    ///
    /// `lines` is a `JSONValue`, not an `Int?`, because the Bun node can and does
    /// put a NON-NUMBER there: `/api/pane/<id>?lines=abc` is `Number("abc")` =
    /// NaN, herdr.ts's `opts.lines ?? 200` is nullish so NaN survives, and the
    /// request goes out as `"lines":null` with a `--lines NaN` cli line. `Int?`
    /// cannot express that; `.number(.nan)` can. nil = the key was absent.
    func readPane(_ paneId: String, source: String?, lines: JSONValue?, format: String?) async throws -> HerdrPaneRead
    /// Raw bytes, no bracketed paste, no Enter.
    func sendText(_ paneId: String, _ text: String) async throws
    /// herdr's key grammar: `Enter`, `Escape`, `ctrl+c`, `shift+tab`, single characters.
    func sendKeys(_ paneId: String, _ keys: [String]) async throws
    /// `sendText` then `sendKeys(["Enter"])`.
    func prompt(_ paneId: String, _ text: String) async throws
    /// `pane.list` with a 1500 ms timeout; never throws.
    func isUp() async -> Bool
    /// Newest first, capped at 200.
    func calls() async -> [CallRecord]
}

// MARK: - identity.ts

public struct Identity: Codable, Sendable, Equatable {
    public var node: String
    /// raw ed25519 public key, hex (64 chars)
    public var pubkey: String
    /// first 16 hex chars
    public var fingerprint: String
    public init(node: String, pubkey: String, fingerprint: String) { self.node = node; self.pubkey = pubkey; self.fingerprint = fingerprint }
}

// MARK: - wire.ts — console and peer shapes

/// A pane as the console sees it.
public struct Member: Codable, Sendable, Equatable {
    public var handle: String
    public var kind: String
    public var `where`: String?
    public var status: AgentStatus?
    public var pane: String
    public var terminal: String?
    public var focused: Bool?
    public var revision: Int?
    public var scrollback: Int?
    public var rows: Int?
    public var tab: String?
    public var workspace: String?
    public var workspaceLabel: String?
    public var repo: String?
    public init(handle: String, kind: String, pane: String) { self.handle = handle; self.kind = kind; self.pane = pane }
}

public struct UiWorkspace: Codable, Sendable, Equatable {
    public var id: String
    public var label: String?
    public var number: Int?
    public var status: AgentStatus?
    public var paneCount: Int?
    public var repo: String?
    public var checkout: String?
    public var linkedWorktree: Bool?
    public init(id: String) { self.id = id }
}

public struct UiTab: Codable, Sendable, Equatable {
    public var id: String
    public var workspace: String
    public var label: String?
    public var number: Int?
    public var status: AgentStatus?
    public var paneCount: Int?
    public init(id: String, workspace: String) { self.id = id; self.workspace = workspace }
}

public struct Topology: Codable, Sendable, Equatable {
    public var workspaces: [UiWorkspace]
    public var tabs: [UiTab]
    public init(workspaces: [UiWorkspace] = [], tabs: [UiTab] = []) { self.workspaces = workspaces; self.tabs = tabs }
}

public struct PeerView: Codable, Sendable, Equatable {
    public var name: String
    public var url: String
    /// set when everything we know came through this hub; `url` is then the hub's
    public var via: String?
    public var ok: Bool?
    public var lastError: String?
    public var lastErrorAt: String?
    public var lastSeen: String?
    public var lastOkAt: String?
    public var consecutive: Int?
    public init(name: String, url: String) { self.name = name; self.url = url }

    /// A peer builds this row from `{ name: p.name, url: p.url, ...health }`, so
    /// a peers.json entry with no `url` emits an object with no `url` key and
    /// Bun reads it back as `undefined`. Neither field is required on the wire.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func str(_ k: CodingKeys) -> String? { ((try? c.decodeIfPresent(String.self, forKey: k)) ?? nil) }
        name = str(.name) ?? ""
        url = str(.url) ?? ""
        via = str(.via)
        ok = (try? c.decodeIfPresent(Bool.self, forKey: .ok)) ?? nil
        lastError = str(.lastError)
        lastErrorAt = str(.lastErrorAt)
        lastSeen = str(.lastSeen)
        lastOkAt = str(.lastOkAt)
        consecutive = (try? c.decodeIfPresent(Int.self, forKey: .consecutive)) ?? nil
    }
}

public struct KnownNode: Codable, Sendable, Equatable {
    public var node: String
    public var url: String?
    public var lastHeard: String
    public init(node: String, url: String?, lastHeard: String) { self.node = node; self.url = url; self.lastHeard = lastHeard }
}

public struct FedMessage: Codable, Sendable, Equatable {
    /// `<origin node>:<seq>` — stable across relays, so dedup is exact
    public var id: String
    public var node: String
    public var seq: Int
    public var from: String
    public var text: String
    public var at: String
    public init(id: String, node: String, seq: Int, from: String, text: String, at: String) {
        self.id = id; self.node = node; self.seq = seq; self.from = from; self.text = text; self.at = at
    }

    /// federation.ts:248 accepts an incoming message on `if (m?.id && …)` and
    /// nothing else — no field is required beyond a truthy `id`. A strict decode
    /// here answered `{"added":0}` to a whole batch that Bun ingested, and lost
    /// the sender introduction with it. `id` stays required (it IS the dedup
    /// key, and a falsy one is rejected on both runtimes); the rest default.
    ///
    /// DIVERGENCE, small and deliberate: Bun keeps an absent `at` as `undefined`
    /// and `JSON.stringify` drops the key on re-export, where this stores "" and
    /// emits `"at":""`. Losing a key beats losing the message.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func str(_ k: CodingKeys) -> String { ((try? c.decodeIfPresent(String.self, forKey: k)) ?? nil) ?? "" }
        id = str(.id)
        guard !id.isEmpty else {
            throw DecodingError.keyNotFound(CodingKeys.id, .init(codingPath: c.codingPath, debugDescription: "message has no id"))
        }
        node = str(.node)
        seq = ((try? c.decodeIfPresent(Int.self, forKey: .seq)) ?? nil) ?? 0
        from = str(.from)
        text = str(.text)
        at = str(.at)
    }
}

/// `GET /api/invite`, and `StatusResponse.invite`. Three explicit nulls.
public struct Invite: Codable, Sendable, Equatable {
    public var node: String
    @NullIfNil public var session: String?
    public var socket: String
    @NullIfNil public var url: String?
    @NullIfNil public var hint: String?
    public init(node: String, session: String?, socket: String, url: String?, hint: String?) {
        self.node = node; self.session = session; self.socket = socket; self.url = url; self.hint = hint
    }
}

/// Lifetime totals. `pushed`/`pullOk` count requests, `pulled` counts messages.
public struct Stats: Codable, Sendable, Equatable {
    public var pushed: Int
    public var pushErrors: Int
    public var pullOk: Int
    public var pullErrors: Int
    public var pulled: Int
    public var errors: Int
    public var bytesOut: Int
    public var bytesIn: Int
    public var startedAt: String
    public init(startedAt: String) {
        pushed = 0; pushErrors = 0; pullOk = 0; pullErrors = 0; pulled = 0; errors = 0; bytesOut = 0; bytesIn = 0
        self.startedAt = startedAt
    }
}

/// `GET /api/status`
public struct StatusResponse: Codable, Sendable, Equatable {
    public var node: String
    public var identity: Identity
    public var legacyAllowed: Bool
    @NullIfNil public var session: String?
    public var invite: Invite
    public var topology: Topology
    public var gossip: Bool
    public var stats: Stats
    public var members: [Member]
    public var messages: [FedMessage]
    public var peers: [PeerView]
    public var peerMembers: [String: [Member]]
    public var peerUi: [String: String]
    public var known: [KnownNode]
    public var relayed: [String: RelayedPeer]?
    public init(node: String, identity: Identity, legacyAllowed: Bool, session: String?, invite: Invite, topology: Topology, gossip: Bool, stats: Stats, members: [Member], messages: [FedMessage], peers: [PeerView], peerMembers: [String: [Member]], peerUi: [String: String], known: [KnownNode], relayed: [String: RelayedPeer]?) {
        self.node = node; self.identity = identity; self.legacyAllowed = legacyAllowed; self.session = session; self.invite = invite; self.topology = topology; self.gossip = gossip; self.stats = stats; self.members = members; self.messages = messages; self.peers = peers; self.peerMembers = peerMembers; self.peerUi = peerUi; self.known = known; self.relayed = relayed
    }
}

public struct CallsResponse: Codable, Sendable { public var calls: [CallRecord]; public init(calls: [CallRecord]) { self.calls = calls } }

/// `POST /api/hey`
public struct HeyRequest: Codable, Sendable { public var to: String?; public var text: String? }
public struct HeyResponse: Codable, Sendable, Equatable {
    /// "pane" | "channel"
    public var delivered: String
    public var to: String?
    public var pane: String?
    public var id: String?
    public init(delivered: String, to: String? = nil, pane: String? = nil, id: String? = nil) { self.delivered = delivered; self.to = to; self.pane = pane; self.id = id }
}

/// `POST /api/broadcast`
public struct BroadcastTarget: Codable, Sendable { public var handle: String; public var pane: String?; public var node: String?; public var base: String? }
public struct BroadcastRequest: Codable, Sendable { public var targets: [BroadcastTarget]?; public var text: String? }
public struct BroadcastResult: Codable, Sendable, Equatable {
    /// `{ handle: t.handle, … }` — a target that carried no handle makes this
    /// `undefined`, and `JSON.stringify` omits the key. Optional, so it does.
    public var handle: String?
    public var node: String?
    public var ok: Bool
    /// "local" | "peer"
    public var via: String?
    public var error: String?
    public init(handle: String?, node: String?, ok: Bool, via: String? = nil, error: String? = nil) { self.handle = handle; self.node = node; self.ok = ok; self.via = via; self.error = error }
}
public struct BroadcastResponse: Codable, Sendable { public var results: [BroadcastResult]; public init(results: [BroadcastResult]) { self.results = results } }

/// `POST /api/peers/join` · `/api/peers/leave`
public struct JoinRequest: Codable, Sendable { public var url: String? }
public struct JoinedNode: Codable, Sendable, Equatable { public var node: String; public var url: String; public init(node: String, url: String) { self.node = node; self.url = url } }
public struct JoinResponse: Codable, Sendable { public var joined: JoinedNode; public init(joined: JoinedNode) { self.joined = joined } }
public struct LeaveRequest: Codable, Sendable { public var name: String? }
public struct LeaveResponse: Codable, Sendable { public var left: String; public init(left: String) { self.left = left } }

/// What a hub republishes about ONE of its direct peers. Strictly one hop.
public struct RelayedPeer: Codable, Sendable, Equatable {
    public var url: String?
    public var members: [Member]
    public var ok: Bool?
    public var lastOkAt: String?
    public var consecutive: Int?
    /// the hub this came through — filled in by the receiving spoke
    /// (`{ ...r, via, members }` appends it, so it is the last member on the wire)
    public var via: String?
    public init(via: String? = nil, url: String?, members: [Member], ok: Bool?, lastOkAt: String?, consecutive: Int?) {
        self.via = via; self.url = url; self.members = members; self.ok = ok; self.lastOkAt = lastOkAt; self.consecutive = consecutive
    }

    /// `members: r.members ?? []` — a hub that sent no roster still relays a node.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        via = try c.decodeIfPresent(String.self, forKey: .via)
        url = try c.decodeIfPresent(String.self, forKey: .url)
        members = try c.decodeIfPresent([Member].self, forKey: .members) ?? []
        ok = try c.decodeIfPresent(Bool.self, forKey: .ok)
        lastOkAt = try c.decodeIfPresent(String.self, forKey: .lastOkAt)
        consecutive = try c.decodeIfPresent(Int.self, forKey: .consecutive)
    }
}

/// `POST /api/fed/hey` — deliver to one of MY panes; caller is an authenticated peer
public struct FedHeyRequest: Codable, Sendable { public var to: String?; public var text: String? }
/// `POST /api/fed/relay` — forward to one of MY DIRECT peers; caller is an authenticated spoke
public struct FedRelayRequest: Codable, Sendable { public var node: String?; public var to: String?; public var text: String? }
/// `POST /api/fed/pane` — read one of MY panes
public struct FedPaneRequest: Codable, Sendable { public var pane: String?; public var lines: Int? }
/// `POST /api/fleet/hey` — the console asking THIS node to deliver anywhere
public struct FleetHeyRequest: Codable, Sendable { public var node: String?; public var to: String?; public var text: String? }
/// `POST /api/fed/pane-relay` and `POST /api/fleet/pane`
public struct FedPaneRelayRequest: Codable, Sendable { public var node: String?; public var pane: String?; public var lines: Int? }
public struct FedPaneResponse: Codable, Sendable, Equatable {
    public var node: String
    public var pane: String
    public var text: String
    public var lines: Int
    public init(node: String, pane: String, text: String, lines: Int) { self.node = node; self.pane = pane; self.text = text; self.lines = lines }
}

/// `GET /api/fed/state` · what `POST /api/fed/ingest` and a pull carry
public struct FedState: Codable, Sendable, Equatable {
    public var node: String
    public var identity: Identity?
    public var messages: [FedMessage]
    public var members: [Member]
    public var peers: [PeerView]
    public var federated: [MemberRecord]?
    public var kicks: [AuditEntry]?
    public var relayed: [String: RelayedPeer]?
    public init(node: String, identity: Identity?, messages: [FedMessage], members: [Member], peers: [PeerView], federated: [MemberRecord]?, kicks: [AuditEntry]?, relayed: [String: RelayedPeer]?) {
        self.node = node; self.identity = identity; self.messages = messages; self.members = members; self.peers = peers; self.federated = federated; self.kicks = kicks; self.relayed = relayed
    }

    /// A pull tolerates a peer that omits any array (`state.messages ?? []`) AND
    /// a peer that sends one bad ROW in an otherwise fine array: federation.ts
    /// requires nothing past `JSON.parse`, so a strict container decode here
    /// would fail the whole link — every `FED_SYNC_MS`, forever — over one
    /// missing field. Each element is decoded on its own and the ones that will
    /// not parse are dropped.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        node = ((try? c.decodeIfPresent(String.self, forKey: .node)) ?? nil) ?? ""
        identity = (try? c.decodeIfPresent(Identity.self, forKey: .identity)) ?? nil
        messages = c.decodeLenientArrayIfPresent(FedMessage.self, forKey: .messages) ?? []
        members = c.decodeLenientArrayIfPresent(Member.self, forKey: .members) ?? []
        peers = c.decodeLenientArrayIfPresent(PeerView.self, forKey: .peers) ?? []
        federated = c.decodeLenientArrayIfPresent(MemberRecord.self, forKey: .federated)
        kicks = c.decodeLenientArrayIfPresent(AuditEntry.self, forKey: .kicks)
        relayed = c.decodeLenientDictionaryIfPresent(RelayedPeer.self, forKey: .relayed)
    }
}

public struct IngestFrom: Codable, Sendable, Equatable {
    public var node: String?
    public var url: String?
    public init(node: String?, url: String?) { self.node = node; self.url = url }
}
public struct IngestRequest: Codable, Sendable { public var messages: [FedMessage]?; public var from: IngestFrom?; public init(messages: [FedMessage]?, from: IngestFrom?) { self.messages = messages; self.from = from } }
public struct IngestResponse: Codable, Sendable, Equatable { public var added: Int; public var node: String; public init(added: Int, node: String) { self.added = added; self.node = node } }

/// `WS /ws/pane/<pane_id>` — server → client
public struct PaneFrame: Codable, Sendable {
    public var type = "frame"
    public var text: String
    public var revision: Int?
    public init(text: String, revision: Int?) { self.text = text; self.revision = revision }
}
public struct PaneErrorMessage: Codable, Sendable {
    public var type = "error"
    public var error: String
    public init(error: String) { self.error = error }
}
/// client → server: `{type:"text",text}` · `{type:"keys",keys:[]}` · `{type:"prompt",text}`
public struct PaneClientMessage: Codable, Sendable {
    public var type: String
    public var text: String?
    public var keys: [String]?
}

// MARK: - membership

/// "active" | "expired" | "revoked" | "exhausted"
public enum InviteStatus: String, Codable, Sendable { case active, expired, revoked, exhausted }

/// An invite link. `token` and `url` are present only on the issuing node.
///
/// Declared in the order the bytes carry, not the order wire.ts's TYPE lists:
/// members.ts builds `{ ...stored, status, url }`, so `status` and `url` come
/// last, and `revokedAt` — assigned onto the stored object later — sits after
/// `usedBy`.
public struct InviteLink: Codable, Sendable, Equatable {
    public var id: String
    @NullIfNil public var token: String?
    public var createdAt: String
    public var createdBy: String
    /// null = never expires
    @NullIfNil public var expiresAt: String?
    /// null = unlimited uses
    @NullIfNil public var maxUses: Int?
    public var uses: Int
    public var note: String?
    public var usedBy: [InviteUse]
    public var revokedAt: String?
    public var status: InviteStatus
    @NullIfNil public var url: String?
    public init(id: String, token: String?, url: String?, createdAt: String, createdBy: String, expiresAt: String?, maxUses: Int?, uses: Int, note: String?, revokedAt: String?, usedBy: [InviteUse], status: InviteStatus) {
        self.id = id; self.token = token; self.url = url; self.createdAt = createdAt; self.createdBy = createdBy; self.expiresAt = expiresAt; self.maxUses = maxUses; self.uses = uses; self.note = note; self.revokedAt = revokedAt; self.usedBy = usedBy; self.status = status
    }
}
public struct InviteUse: Codable, Sendable, Equatable { public var node: String; public var at: String; public init(node: String, at: String) { self.node = node; self.at = at } }

/// A node we federate with. Tokens are never part of this view.
public struct MemberRecord: Codable, Sendable, Equatable {
    public var node: String
    public var pubkey: String
    public var fingerprint: String
    public var url: String?
    public var joinedAt: String
    public var viaInvite: String?
    public var lastSeen: String?
    public var legacy: Bool?
    public init(node: String, pubkey: String, fingerprint: String, url: String?, joinedAt: String, viaInvite: String? = nil, lastSeen: String? = nil, legacy: Bool? = nil) {
        self.node = node; self.pubkey = pubkey; self.fingerprint = fingerprint; self.url = url; self.joinedAt = joinedAt; self.viaInvite = viaInvite; self.lastSeen = lastSeen; self.legacy = legacy
    }
}

public struct BanRecord: Codable, Sendable, Equatable {
    public var node: String
    public var pubkey: String
    public var at: String
    public var by: String
    public var reason: String?
    public init(node: String, pubkey: String, at: String, by: String, reason: String?) { self.node = node; self.pubkey = pubkey; self.at = at; self.by = by; self.reason = reason }
}

public enum AuditAction: String, Codable, Sendable {
    case inviteCreate = "invite.create"
    case inviteRevoke = "invite.revoke"
    case memberJoin = "member.join"
    case memberKick = "member.kick"
    case memberBan = "member.ban"
    case memberUnban = "member.unban"
    case redeemReject = "redeem.reject"
    case kickAdopt = "kick.adopt"
}

public struct AuditStep: Codable, Sendable, Equatable {
    public var n: Int
    public var label: String
    public var wire: String?
    public var ok: Bool
    public var detail: String?
    public init(n: Int, label: String, wire: String? = nil, ok: Bool, detail: String? = nil) { self.n = n; self.label = label; self.wire = wire; self.ok = ok; self.detail = detail }
}

public struct AuditEntry: Codable, Sendable, Equatable {
    public var id: String
    public var at: String
    public var action: AuditAction
    public var node: String
    public var by: String
    public var reason: String?
    public var summary: String?
    public var steps: [AuditStep]
    /// only on `AdminState.adoptable` — the peer that published the kick
    public var from: String?
    public init(id: String, at: String, action: AuditAction, node: String, by: String, reason: String?, summary: String?, steps: [AuditStep], from: String? = nil) {
        self.id = id; self.at = at; self.action = action; self.node = node; self.by = by; self.reason = reason; self.summary = summary; self.steps = steps; self.from = from
    }
}

/// One edge of the federation, both halves.
public struct FedEdge: Codable, Sendable, Equatable {
    public var peer: String
    public var url: String
    public var ours: Bool
    public var theirs: Bool
    public var mutual: Bool
    public var stale: Bool
    /// agents, not panes — `kind` present and not "shell"
    public var panes: Int
    public var ok: Bool?
    public var consecutive: Int?
    public var lastSeen: String?
    public var lastOkAt: String?
    public var lastError: String?
    public init(peer: String, url: String, ours: Bool, theirs: Bool, mutual: Bool, stale: Bool, panes: Int, ok: Bool?, consecutive: Int?, lastSeen: String?, lastOkAt: String?, lastError: String?) {
        self.peer = peer; self.url = url; self.ours = ours; self.theirs = theirs; self.mutual = mutual; self.stale = stale; self.panes = panes; self.ok = ok; self.consecutive = consecutive; self.lastSeen = lastSeen; self.lastOkAt = lastOkAt; self.lastError = lastError
    }
}

/// `GET /api/admin`
public struct AdminState: Codable, Sendable, Equatable {
    public var node: String
    public var identity: Identity
    public var legacyAllowed: Bool
    public var members: [MemberRecord]
    public var invites: [InviteLink]
    public var bans: [BanRecord]
    public var audit: [AuditEntry]
    public var meshMembers: [String: [MemberRecord]]
    public var adoptable: [AuditEntry]
    public var edges: [FedEdge]
    /// before `panes` — the literal at server.ts:646 lists heard, panes, peerPanes
    public var heard: [KnownNode]
    public var panes: [Member]
    public var peerPanes: [String: [Member]]
    public var relayed: [String: RelayedPeer]?
    public init(node: String, identity: Identity, legacyAllowed: Bool, members: [MemberRecord], invites: [InviteLink], bans: [BanRecord], audit: [AuditEntry], meshMembers: [String: [MemberRecord]], adoptable: [AuditEntry], edges: [FedEdge], panes: [Member], peerPanes: [String: [Member]], heard: [KnownNode], relayed: [String: RelayedPeer]?) {
        self.node = node; self.identity = identity; self.legacyAllowed = legacyAllowed; self.members = members; self.invites = invites; self.bans = bans; self.audit = audit; self.meshMembers = meshMembers; self.adoptable = adoptable; self.edges = edges; self.panes = panes; self.peerPanes = peerPanes; self.heard = heard; self.relayed = relayed
    }
}

/// `POST /api/invites` — `{ hours = 24, uses = null, note }`: an ABSENT hours is
/// 24, an explicit null is "never expires"; uses absent or null is unlimited.
///
/// `hours` and `uses` are `Double`, not `Int`: members.ts does `hours * 3600_000`
/// on whatever arrived, so `{"hours":0.5}` is a 30-minute invite on the fleet.
/// Typing them as `Int` made the WHOLE struct fail to decode on a fractional or
/// string value, and every field then reverted to its default — an invite asked
/// to live 30 minutes lived 24 hours. The route now reads the keys one at a time
/// with `Number()` coercion, so one odd field cannot extend another's lifetime.
public struct CreateInviteRequest: Codable, Sendable {
    public var hours: Nullable<Double> = .absent
    public var uses: Nullable<Double> = .absent
    public var note: String?
    public init(hours: Nullable<Double> = .absent, uses: Nullable<Double> = .absent, note: String? = nil) { self.hours = hours; self.uses = uses; self.note = note }
}
public struct CreateInviteResponse: Codable, Sendable { public var invite: InviteLink; public init(invite: InviteLink) { self.invite = invite } }
public struct InvitesResponse: Codable, Sendable { public var invites: [InviteLink]; public init(invites: [InviteLink]) { self.invites = invites } }

/// `POST /api/peers/redeem` — our console telling our node to go join someone
public struct RedeemRequest: Codable, Sendable { public var from: String?; public var token: String? }
public struct RedeemResponse: Codable, Sendable { public var joined: JoinedNode; public var entry: AuditEntry; public init(joined: JoinedNode, entry: AuditEntry) { self.joined = joined; self.entry = entry } }

/// `POST /api/fed/redeem` — the joiner presenting an invite to the issuer
public struct FedRedeemRequest: Codable, Sendable, Equatable {
    public var token: String
    public var node: String
    public var pubkey: String
    public var url: String?
    /// the token WE issue to THEM, so one round trip authenticates both directions
    public var offerToken: String
    public var at: String
    public var sig: String
    /// NOT on the wire. members.ts:201 records a rejection under
    /// `req.node ?? "unknown"`, so an ABSENT `node` key reads "unknown" in the
    /// audit log while an explicit `""` stays `""` — `??` catches only
    /// null/undefined. A plain `String` cannot tell those apart, so the route
    /// records which it saw.
    public var nodePresent: Bool = true
    /// `nodePresent` is deliberately excluded: it is presence, not payload.
    enum CodingKeys: String, CodingKey { case token, node, pubkey, url, offerToken, at, sig }
    public init(token: String, node: String, pubkey: String, url: String?, offerToken: String, at: String, sig: String, nodePresent: Bool = true) {
        self.token = token; self.node = node; self.pubkey = pubkey; self.url = url; self.offerToken = offerToken; self.at = at; self.sig = sig; self.nodePresent = nodePresent
    }
    /// members.ts's `req.node ?? "unknown"`.
    public var auditNode: String { nodePresent ? node : "unknown" }
}
public struct FedRedeemResponse: Codable, Sendable, Equatable {
    public var node: String
    public var pubkey: String
    public var url: String?
    public var memberToken: String
    public init(node: String, pubkey: String, url: String?, memberToken: String) { self.node = node; self.pubkey = pubkey; self.url = url; self.memberToken = memberToken }
}

/// `GET /api/invite-preview/:token`
public struct InvitePreview: Codable, Sendable, Equatable {
    public var node: String
    public var fingerprint: String
    @NullIfNil public var url: String?
    @NullIfNil public var expiresAt: String?
    public var createdBy: String
    public var note: String?
    public var status: InviteStatus
    public var members: Int
    public init(node: String, fingerprint: String, url: String?, expiresAt: String?, createdBy: String, note: String?, status: InviteStatus, members: Int) {
        self.node = node; self.fingerprint = fingerprint; self.url = url; self.expiresAt = expiresAt; self.createdBy = createdBy; self.note = note; self.status = status; self.members = members
    }
}

/// `POST /api/members/:node/kick` · `/ban` · `/unban`
public struct KickRequest: Codable, Sendable { public var reason: String? }
public struct KickResponse: Codable, Sendable { public var entry: AuditEntry; public init(entry: AuditEntry) { self.entry = entry } }
public struct MembersResponse: Codable, Sendable { public var members: [MemberRecord]; public var bans: [BanRecord]; public init(members: [MemberRecord], bans: [BanRecord]) { self.members = members; self.bans = bans } }
public struct AuditResponse: Codable, Sendable { public var audit: [AuditEntry]; public init(audit: [AuditEntry]) { self.audit = audit } }
/// `POST /api/audit/adopt`
public struct AdoptRequest: Codable, Sendable { public var from: String?; public var node: String?; public var reason: String? }

/// Any endpoint can answer with this instead.
public struct ErrorResponse: Codable, Sendable, Equatable { public var error: String; public init(_ error: String) { self.error = error } }

/// The exact string a joiner signs. Both ends must build it identically.
public func redeemMessage(token: String, node: String, at: String) -> String {
    "herdr-federation:redeem:\(token):\(node):\(at)"
}

// MARK: - members.ts — the membership store

/// `RedeemFailure` in members.ts. `/api/fed/redeem` answers 403 for `.banned`, 400 otherwise,
/// with body `{ error: "<code>: <message>" }`.
public enum RedeemFailure: String, Sendable {
    case unknownInvite = "unknown_invite", revoked, expired, exhausted, banned
    case badSignature = "bad_signature", staleRequest = "stale_request", `self`
}

public struct RedeemError: Error, Sendable, Equatable {
    public var code: RedeemFailure
    public var message: String
    public init(code: RedeemFailure, message: String) { self.code = code; self.message = message }
}

/// What `adopt()` records after WE redeemed somewhere.
public struct AdoptedPeer: Sendable {
    public var node: String
    public var pubkey: String
    public var url: String?
    public var ourToken: String
    public var theirToken: String
    public init(node: String, pubkey: String, url: String?, ourToken: String, theirToken: String) {
        self.node = node; self.pubkey = pubkey; self.url = url; self.ourToken = ourToken; self.theirToken = theirToken
    }
}

/// Invites, members, bans, and the audit log. Persisted to `.fed-members.json`
/// in the SAME layout the Bun node writes — `{invites, members, bans, audit}`,
/// pretty-printed, members carrying `ourToken`/`theirToken` on disk and never
/// in any view. Enforcement is local only.
public protocol MembersStore: AnyObject, Sendable {
    var node: String { get }
    func load() async
    func save() async

    // audit
    func record(_ action: AuditAction, node: String, steps: [AuditStep], reason: String?, summary: String?) async -> AuditEntry
    /// newest first
    func audit() async -> [AuditEntry]
    /// the last 50 kicks and bans, oldest first
    func publishedKicks() async -> [AuditEntry]

    // invites
    /// newest first, each with `status` and `url` computed
    func invites() async -> [InviteLink]
    func createInvite(_ req: CreateInviteRequest) async -> InviteLink
    /// nil when unknown or already revoked
    func revokeInvite(_ inviteId: String) async -> InviteLink?
    func preview(token: String) async -> (invite: InviteLink, status: InviteStatus)?

    // members
    /// tokens stripped
    func members() async -> [MemberRecord]
    /// newest first
    func bans() async -> [BanRecord]
    /// the token to present when calling this peer
    func tokenFor(_ node: String) async -> String?
    /// matching `ourToken` IS the authentication; stamps `lastSeen`
    func authenticate(token: String?) async -> MemberRecord?
    func isBanned(pubkey: String, node: String) async -> Bool
    /// the only place a new relationship is born; throws `RedeemError`
    func redeem(_ req: FedRedeemRequest) async throws -> (memberToken: String, entry: AuditEntry)
    func adopt(_ peer: AdoptedPeer, steps: [AuditStep], summary: String?) async -> AuditEntry
    /// a pre-token peer: recorded flagged `legacy`, no-op if already a member
    func adoptLegacy(node: String, url: String?) async
    /// nil when not a member. `adopted` = the peer whose kick we adopted → action `kick.adopt`
    func kick(node: String, reason: String?, adopted: String?) async -> AuditEntry?
    func ban(node: String, reason: String?) async -> AuditEntry
    func unban(node: String) async -> AuditEntry?
    func adoptKick(node: String, from: String, reason: String?) async -> AuditEntry?
}

// MARK: - federation.ts — peers, sync, hub relay

public struct Peer: Codable, Sendable, Equatable {
    public var name: String
    public var url: String
    public var via: String?
    public init(name: String, url: String, via: String? = nil) { self.name = name; self.url = url; self.via = via }
}

public struct PeerHealth: Codable, Sendable, Equatable {
    public var ok: Bool?
    public var lastError: String?
    public var lastErrorAt: String?
    public var lastSeen: String?
    public var lastOkAt: String?
    /// failed attempts since the last success — 0 means the link is fine right now
    public var consecutive: Int
    /// the address that last completed a sync; evidence, versus an advertised claim
    public var lastOkUrl: String?
    public init(consecutive: Int = 0) { self.consecutive = consecutive }
}

/// `peers.json` — `{ node, gossip?, peers: [{name, url}] }`, pretty-printed on save.
public struct FedConfig: Codable, Sendable, Equatable {
    public var node: String
    public var gossip: Bool?
    public var peers: [Peer]
    public init(node: String, gossip: Bool?, peers: [Peer]) { self.node = node; self.gossip = gossip; self.peers = peers }
}

/// A relayed node as this spoke holds it: `RelayedPeer & { via: string }`.
public struct RelayedEntry: Sendable, Equatable {
    public var via: String
    public var url: String?
    public var members: [Member]
    public var ok: Bool?
    public var lastOkAt: String?
    public var consecutive: Int?
    public init(via: String, url: String?, members: [Member], ok: Bool?, lastOkAt: String?, consecutive: Int?) {
        self.via = via; self.url = url; self.members = members; self.ok = ok; self.lastOkAt = lastOkAt; self.consecutive = consecutive
    }
    public var asRelayedPeer: RelayedPeer { RelayedPeer(via: via, url: url, members: members, ok: ok, lastOkAt: lastOkAt, consecutive: consecutive) }
}

/// A reply from a peer, for the callers that read the status and the body.
public struct PeerReply: Sendable {
    public var status: Int
    public var body: Data
    public init(status: Int, body: Data) { self.status = status; self.body = body }
    public var ok: Bool { (200..<300).contains(status) }
}

/// The message log and peer sync. Outbound-only in both directions. State on
/// disk at `.fed-state.json` as `{ seq, messages }` (compact, last 500).
public protocol FederationSync: AnyObject, Sendable {
    var node: String { get }
    func config() async -> FedConfig
    func peers() async -> [Peer]
    /// a direct peer by name — the test for "can we act on this node ourselves"
    func peer(_ name: String) async -> Peer?
    func health() async -> [String: PeerHealth]
    func known() async -> [String: KnownNode]
    func peerMembers() async -> [String: [Member]]
    func peerUi() async -> [String: String]
    func relayed() async -> [String: RelayedEntry]
    func peerFederated() async -> [String: [MemberRecord]]
    func peerKicks() async -> [String: [AuditEntry]]

    // The same three maps in INSERTION order. Contract.swift waives member order
    // for `Record<string, …>` OBJECT fields only; `known`, `heard`, `adoptable`
    // and the relayed rows appended to `/api/status.peers` are ARRAYS, where
    // order survives parsing and is what the console renders. Bun builds them
    // with `Object.values(...)` / `Object.entries(...)`, i.e. the order nodes
    // were first heard of or first relayed; a Swift Dictionary's order is seeded
    // per process and shifts as it grows. These preserve it.
    /// `Object.values(fed.known)`
    func knownList() async -> [KnownNode]
    /// `Object.entries(fed.relayed)`
    func relayedList() async -> [(name: String, entry: RelayedEntry)]
    /// `Object.entries(fed.peerKicks)`
    func peerKicksList() async -> [(from: String, entries: [AuditEntry])]
    func stats() async -> Stats
    func messages() async -> [FedMessage]
    func advertised() async -> String?
    func setAdvertised(_ url: String?) async

    func load() async
    func save() async

    /// evidence beats a claim: never replace an address that has completed a sync
    func addPeer(name: String, url: String) async
    /// probe `<url>/api/fed/state`, learn the node's name, adopt it, pull once
    func join(url: String) async throws -> JoinedNode
    func leave(_ name: String) async
    /// an authenticated call to a DIRECT peer; throws when `name` is not one
    func call(_ name: String, path: String, method: String, body: Data?) async throws -> PeerReply

    /// record a message this node originated, persist, push to every peer (not awaited)
    func post(from: String, text: String) async -> FedMessage
    /// exact dedup by origin id; returns how many were new
    func ingest(_ incoming: [FedMessage], from: IngestFrom?) async -> Int
    func pushAll() async
    func pullAll() async
}

/// `String(err)` for a failed peer call — the text that lands in `PeerHealth.lastError`.
/// `name` is the JS error class: `Error` for a fetch that could not connect,
/// `TimeoutError` for an `AbortSignal.timeout`, `SyntaxError` for a reply that
/// was not JSON. `errorText()` strips only `Error:`, exactly as server.ts's
/// `.replace(/^Error:\s*/, "")` does — so `TimeoutError: …` reaches the wire whole.
public struct FederationError: Error, CustomStringConvertible, Sendable, Equatable {
    public var name: String
    public var message: String
    public init(_ message: String, name: String = "Error") { self.message = message; self.name = name }
    public var description: String { "\(name): \(message)" }
}

// MARK: - server.ts — what the routes and the pane stream share

/// Who is watching a pane, so a send can refresh those viewers at once.
public protocol PaneNudger: AnyObject, Sendable {
    /// after we type into a pane, push a frame now instead of waiting for the next tick
    func nudge(_ paneId: String) async
}

/// The one local delivery path: by pane id or handle, `prompt` then nudge.
/// Thrown as `NodeError("no agent <to> on <node>")` when nothing matches.
public struct NodeError: Error, CustomStringConvertible, Sendable, Equatable {
    public var message: String
    public init(_ message: String) { self.message = message }
    public var description: String { "Error: \(message)" }
}

/// Strip the `Error: ` that `String(err)` puts in front — `.replace(/^Error:\s*/, "")`.
public func errorText(_ error: Error) -> String {
    let s: String
    s = (error as CustomStringConvertible).description
    guard s.hasPrefix("Error:") else { return s }
    return String(s.dropFirst("Error:".count)).drimmingLeadingWhitespace()
}

extension String {
    /// the `\s*` after `Error:`
    func drimmingLeadingWhitespace() -> String {
        String(drop(while: { $0 == " " || $0 == "\t" || $0 == "\n" }))
    }
}

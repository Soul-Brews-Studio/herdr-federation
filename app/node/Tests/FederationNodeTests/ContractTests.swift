import XCTest
@testable import FederationNode

/// The contract's JSON conventions, pinned: explicit nulls where wire.ts says
/// `| null`, omitted keys where it says `?`, three-way presence for `hours`.
final class ContractTests: XCTestCase {
    func testInviteEncodesExplicitNulls() throws {
        let inv = Invite(node: "m5", session: nil, socket: "/tmp/h.sock", url: nil, hint: "set FED_ADVERTISE")
        let json = String(decoding: try JSONCoding.encode(inv), as: UTF8.self)
        XCTAssertTrue(json.contains("\"session\":null"), json)
        XCTAssertTrue(json.contains("\"url\":null"), json)
        XCTAssertFalse(json.contains("\\/"), "slashes must not be escaped")
    }

    func testOptionalKeysAreOmitted() throws {
        let m = Member(handle: "neo", kind: "claude", pane: "w2V:p1")
        let json = String(decoding: try JSONCoding.encode(m), as: UTF8.self)
        XCTAssertFalse(json.contains("where"), json)
        XCTAssertFalse(json.contains("null"), json)
    }

    func testNullIfNilDecodesMissingKey() throws {
        let data = Data("{\"node\":\"x\",\"socket\":\"s\"}".utf8)
        let inv = try JSONCoding.decode(Invite.self, from: data)
        XCTAssertNil(inv.session)
        XCTAssertNil(inv.url)
    }

    func testCreateInviteThreeWayHours() throws {
        let absent = try JSONCoding.decode(CreateInviteRequest.self, from: Data("{}".utf8))
        let null = try JSONCoding.decode(CreateInviteRequest.self, from: Data("{\"hours\":null}".utf8))
        let value = try JSONCoding.decode(CreateInviteRequest.self, from: Data("{\"hours\":2}".utf8))
        guard case .absent = absent.hours else { return XCTFail("absent") }
        guard case .null = null.hours else { return XCTFail("null") }
        XCTAssertEqual(value.hours.value, 2)
    }

    /// federation.ts reads a pulled body off a loose `JSON.parse` and validates
    /// nothing, so ONE bad row must cost that row and nothing else. A strict
    /// container decode failed the whole pull as `SyntaxError: JSON Parse error`
    /// and threw away the roster, the kicks and every message with it.
    func testFedStateKeepsEveryRowItCanParse() throws {
        let raw = """
        {"node":"x",
         "peers":[{"name":"noURL"},{"name":"ok","url":"http://o"}],
         "messages":[{"id":"x:1","node":"x","seq":1,"from":"a","text":"hi"},
                     {"node":"x","seq":2,"from":"a","text":"no id"},
                     {"id":"x:3","node":"x","seq":3,"from":"a","text":"no at"}],
         "members":[{"handle":"h","kind":"claude","pane":"p"}],
         "federated":[{"node":"n","pubkey":"p","fingerprint":"f","joinedAt":"t"},{"bad":1}]}
        """
        let state = try JSONCoding.decode(FedState.self, from: Data(raw.utf8))
        // a peer with no `url` survives as an empty one, the way `p.url` is undefined on Bun
        XCTAssertEqual(state.peers.map(\.name), ["noURL", "ok"])
        XCTAssertEqual(state.peers[0].url, "")
        // only the id-less message is dropped — `if (m?.id && …)` is Bun's whole filter
        XCTAssertEqual(state.messages.map(\.id), ["x:1", "x:3"])
        XCTAssertEqual(state.messages[1].at, "", "an absent `at` defaults rather than failing the row")
        XCTAssertEqual(state.members.count, 1)
        XCTAssertEqual(state.federated?.map(\.node), ["n"])
    }

    /// `Number()` semantics for the three numeric env vars, not `Int(...)`:
    /// `FED_PORT=` exported-but-empty is 0 (an ephemeral port under Bun), and a
    /// trailing space does not throw the value away.
    func testEnvNumbersUseJSCoercion() {
        XCTAssertEqual(jsEnvNumber(nil, default: 6750), 6750)
        XCTAssertEqual(jsEnvNumber("", default: 6750), 0)
        XCTAssertEqual(jsEnvNumber("  ", default: 6750), 0)
        XCTAssertEqual(jsEnvNumber("6751 ", default: 6750), 6751)
        XCTAssertEqual(jsEnvNumber("6751", default: 6750), 6751)
        // NaN is a documented divergence: Bun hands NaN to Bun.serve, this keeps the default
        XCTAssertEqual(jsEnvNumber("abc", default: 6750), 6750)
    }

    /// `{ ...config, peers }` keeps every key where it was; the scanner is what
    /// tells saveConfig() where that is, because a Dictionary no longer knows.
    func testTopLevelKeyOrderIsReadOffTheBytes() {
        let raw = #"{"node":"m5","peers":[{"name":"a","url":"http://a"}],"gossip":true,"label":"x"}"#
        XCTAssertEqual(jsonTopLevelKeyOrder(Data(raw.utf8)), ["node", "peers", "gossip", "label"])
        // nested keys are not top level, and an escaped key is unescaped by the decoder
        let nested = "{\"a\":{\"b\":1},\"c\\\"d\":2}"
        XCTAssertEqual(jsonTopLevelKeyOrder(Data(nested.utf8)), ["a", "c\"d"])
    }

    func testClockIsoMatchesJS() {
        let s = Stamp.iso(Date(timeIntervalSince1970: 1_800_000_000.5))
        XCTAssertEqual(s, "2027-01-15T08:00:00.500Z")
        XCTAssertNotNil(Stamp.parse(s))
        XCTAssertNotNil(Stamp.parse("2026-09-22T04:02:00Z"))
        XCTAssertNil(Stamp.parse("yesterday"))
    }

    func testJSONValueRoundTrip() throws {
        let raw = Data("{\"pane_id\":\"w1:p1\",\"lines\":40,\"keys\":[\"Enter\"],\"n\":null,\"ok\":true}".utf8)
        let v = try JSONCoding.decode(JSONValue.self, from: raw)
        XCTAssertEqual(v["lines"]?.intValue, 40)
        let out = String(decoding: try JSONCoding.encode(v), as: UTF8.self)
        XCTAssertTrue(out.contains("\"lines\":40"), out)   // not 40.0
    }

    func testErrorText() {
        XCTAssertEqual(errorText(NodeError("no agent x on m5")), "no agent x on m5")
        XCTAssertEqual(errorText(HerdrError(code: "timeout", message: "pane.read timed out")), "pane.read timed out")
        // `.replace(/^Error:\s*/, "")` leaves every other JS error class whole
        XCTAssertEqual(errorText(FederationError("The operation timed out.", name: "TimeoutError")), "TimeoutError: The operation timed out.")
        XCTAssertEqual(errorText(FederationError("Failed to parse JSON", name: "SyntaxError")), "SyntaxError: Failed to parse JSON")
        XCTAssertEqual(FederationError("x").description, "Error: x")
    }

    func testWireOrderFollowsTheBunLiterals() throws {
        // members.ts: `{ ...stored, status, url }` — status and url come LAST
        let inv = InviteLink(id: "abcdefgh", token: "t", url: "http://m5/join/t", createdAt: "c", createdBy: "m5",
                             expiresAt: nil, maxUses: nil, uses: 0, note: nil, revokedAt: nil, usedBy: [], status: .active)
        XCTAssertEqual(String(decoding: try JSONCoding.encode(inv), as: UTF8.self),
                       "{\"id\":\"abcdefgh\",\"token\":\"t\",\"createdAt\":\"c\",\"createdBy\":\"m5\",\"expiresAt\":null,\"maxUses\":null,\"uses\":0,\"usedBy\":[],\"status\":\"active\",\"url\":\"http://m5/join/t\"}")
        // federation.ts: `{ ...r, via, members }` — via is appended by the spoke
        let r = RelayedPeer(via: "hub", url: "http://far", members: [], ok: true, lastOkAt: nil, consecutive: 0)
        XCTAssertEqual(String(decoding: try JSONCoding.encode(r), as: UTF8.self),
                       "{\"url\":\"http://far\",\"members\":[],\"ok\":true,\"consecutive\":0,\"via\":\"hub\"}")
    }

    func testAccessLogLine() {
        let log = AccessLog(on: true, debug: false)
        let line = log.line(method: "GET", path: "/api/status", status: 200, ms: 12)
        // status 3 wide · method 4 wide · path 34 wide · "12ms" right-aligned in 6
        XCTAssertTrue(line.hasSuffix("] 200 GET  /api/status" + String(repeating: " ", count: 23) + "   12ms"), line)
    }

    func testSnapshotVersionIsTheStringHerdrSends() throws {
        // what herdr 0.9.1 (protocol 22) actually puts on the wire
        let live = Data("{\"version\":\"0.9.1\",\"protocol\":22,\"workspaces\":[],\"tabs\":[],\"panes\":[{\"pane_id\":\"w1:p1\"}],\"agents\":[]}".utf8)
        let snap = try JSONCoding.decode(HerdrSnapshot.self, from: live)
        XCTAssertEqual(snap.version, "0.9.1")
        XCTAssertEqual(snap.protocolVersion, 22)
        XCTAssertEqual(snap.panes.map(\.pane_id), ["w1:p1"])
        // protocol.ts's `number` — never seen on the wire; must not kill the snapshot either
        let declared = Data("{\"version\":22,\"panes\":[]}".utf8)
        XCTAssertNil(try JSONCoding.decode(HerdrSnapshot.self, from: declared).version)
    }

    func testPaneReadWithoutTextDecodes() throws {
        // server.ts reads `read.text ?? ""` — a reply without text is an empty frame, not a failure
        let read = try JSONCoding.decode(HerdrPaneRead.self, from: Data("{\"pane_id\":\"w1:p1\",\"revision\":0}".utf8))
        XCTAssertNil(read.text)
        XCTAssertNil(read.source)
        XCTAssertEqual(read.revision, 0)
    }

    func testPortGuardPrintsBunsHardcodedPort() {
        // server.ts:270 says `FED_PORT=6751` whatever port was refused
        let env = NodeEnv(root: "/r", environment: ["FED_PORT": "6762"])
        let lines = portGuardMessage(env: env, servingNode: "m5")
        XCTAssertEqual(lines.count, 4)
        XCTAssertEqual(lines[0], "[fed] port 6762 is already serving node \"m5\" — refusing to start a second one.")
        XCTAssertEqual(lines[2], "[fed]   use another port:  FED_PORT=6751 ...")
        XCTAssertEqual(lines[3], "[fed]   or stop that one:  just node stop")
    }

    func testEnvDefaults() {
        let env = NodeEnv(root: "/r", environment: ["HOME": "/h"])
        XCTAssertEqual(env.port, 6750)
        XCTAssertEqual(env.host, "127.0.0.1")
        XCTAssertTrue(env.allowLegacy)
        XCTAssertNil(env.publicBase())
        XCTAssertEqual(env.socketPath, "/h/.config/herdr/herdr.sock")
        XCTAssertEqual(env.configPath, "/r/peers.json")
        let adv = NodeEnv(root: "/r", environment: ["FED_ADVERTISE": "10.0.0.1", "FED_PORT": "6751", "FED_ALLOW_LEGACY": "0", "FED_LOG": "DEBUG"])
        XCTAssertEqual(adv.publicBase(), "http://10.0.0.1:6751")
        XCTAssertFalse(adv.allowLegacy)
        XCTAssertTrue(adv.logDebug)
    }
}

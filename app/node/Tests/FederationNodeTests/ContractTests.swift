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
    }

    func testAccessLogLine() {
        let log = AccessLog(on: true, debug: false)
        let line = log.line(method: "GET", path: "/api/status", status: 200, ms: 12)
        // status 3 wide · method 4 wide · path 34 wide · "12ms" right-aligned in 6
        XCTAssertTrue(line.hasSuffix("] 200 GET  /api/status" + String(repeating: " ", count: 23) + "   12ms"), line)
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

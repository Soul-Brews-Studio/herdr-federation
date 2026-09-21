import XCTest
@testable import FederationNode

/// Every expected string below was printed by Bun 1.3.14 (`JSON.stringify`) for
/// the same value, and pasted here unchanged. The encoder is right when its
/// bytes are Bun's bytes.
private struct Inner: Encodable { var g = 2 }
private struct S: Encodable { var t: [JSONValue] = [.object([:])] }
private struct R: Encodable { var s = S() }
private struct Fixture: Encodable {
    var a = 1
    var b = "x/y"
    @NullIfNil var c: String? = nil
    var d: [Int] = []
    var e: JSONValue = .object([:])
    var f: JSONValue = .array([.number(1), .object(["g": .number(2)])])
    var h = "\u{01}\"\\\n\t\u{08}\u{0C}\r\u{1f}"
    var i = 1.5
    var j = -0.0
    var k = 1e21
    var l = 123456789012345680000.0
    var m = "é\u{2028}"
    var n = 0.1 + 0.2
    var o = 1e-7
    var p = true
    var q: JSONValue = .array([.null, .array([])])
    var r = R()
}

final class JSONStringifyTests: XCTestCase {
    func testCompactMatchesBunByteForByte() throws {
        let out = try JSONStringify.string(Fixture())
        XCTAssertEqual(out, "{\"a\":1,\"b\":\"x/y\",\"c\":null,\"d\":[],\"e\":{},\"f\":[1,{\"g\":2}],\"h\":\"\\u0001\\\"\\\\\\n\\t\\b\\f\\r\\u001f\",\"i\":1.5,\"j\":0,\"k\":1e+21,\"l\":123456789012345680000,\"m\":\"é\u{2028}\",\"n\":0.30000000000000004,\"o\":1e-7,\"p\":true,\"q\":[null,[]],\"r\":{\"s\":{\"t\":[{}]}}}")
    }

    func testPrettyMatchesBunByteForByte() throws {
        let out = try JSONStringify.string(Fixture(), pretty: true)
        let expected = [
            "{",
            "  \"a\": 1,",
            "  \"b\": \"x/y\",",
            "  \"c\": null,",
            "  \"d\": [],",
            "  \"e\": {},",
            "  \"f\": [",
            "    1,",
            "    {",
            "      \"g\": 2",
            "    }",
            "  ],",
            "  \"h\": \"\\u0001\\\"\\\\\\n\\t\\b\\f\\r\\u001f\",",
            "  \"i\": 1.5,",
            "  \"j\": 0,",
            "  \"k\": 1e+21,",
            "  \"l\": 123456789012345680000,",
            "  \"m\": \"é\u{2028}\",",
            "  \"n\": 0.30000000000000004,",
            "  \"o\": 1e-7,",
            "  \"p\": true,",
            "  \"q\": [",
            "    null,",
            "    []",
            "  ],",
            "  \"r\": {",
            "    \"s\": {",
            "      \"t\": [",
            "        {}",
            "      ]",
            "    }",
            "  }",
            "}",
        ].joined(separator: "\n")
        XCTAssertEqual(out, expected)
    }

    func testNumbersPrintLikeJavaScript() throws {
        let big: [Double] = [9007199254740992, 1e15, 1e16, 123456789012345678, -1e20, 1.0, 100, 9007199254740992]
        XCTAssertEqual(try JSONStringify.string(big),
                       "[9007199254740992,1000000000000000,10000000000000000,123456789012345680,-100000000000000000000,1,100,9007199254740992]")
        let small: [Double] = [0.000001, 0.0000001, 1e-6, 1.5e-10, 123.456, 1e100]
        XCTAssertEqual(try JSONStringify.string(small), "[0.000001,1e-7,0.000001,1.5e-10,123.456,1e+100]")
        // JSON.stringify({a:NaN,b:Infinity}) → {"a":null,"b":null}
        XCTAssertEqual(try JSONStringify.string([Double.nan, .infinity, -.infinity]), "[null,null,null]")
        XCTAssertEqual(JSONStringify.numberText(5e-324), "5e-324")
        XCTAssertEqual(JSONStringify.numberText(-0.5), "-0.5")
        XCTAssertEqual(JSONStringify.numberText(1e6), "1000000")
        XCTAssertEqual(JSONStringify.numberText(0.1), "0.1")
    }

    func testMembersComeOutInDeclarationOrder() throws {
        // the order server.ts builds each literal in, which is the order Contract.swift declares
        let call = CallRecord(at: "t", method: "pane.list", params: [:], cli: "herdr pane list", ms: 3, ok: true)
        XCTAssertEqual(try JSONStringify.string(call), "{\"at\":\"t\",\"method\":\"pane.list\",\"params\":{},\"cli\":\"herdr pane list\",\"ms\":3,\"ok\":true}")
        var m = Member(handle: "neo", kind: "claude", pane: "w1:p1")
        m.`where` = "/x"
        m.repo = "neo-oracle"
        XCTAssertEqual(try JSONStringify.string(m), "{\"handle\":\"neo\",\"kind\":\"claude\",\"where\":\"/x\",\"pane\":\"w1:p1\",\"repo\":\"neo-oracle\"}")
        let inv = Invite(node: "m5", session: nil, socket: "/tmp/h.sock", url: nil, hint: "set FED_ADVERTISE")
        XCTAssertEqual(try JSONStringify.string(inv), "{\"node\":\"m5\",\"session\":null,\"socket\":\"/tmp/h.sock\",\"url\":null,\"hint\":\"set FED_ADVERTISE\"}")
    }

    func testJSONCodingRoundTripsEveryShape() throws {
        var member = Member(handle: "neo", kind: "claude", pane: "w1:p1")
        member.focused = true
        member.revision = 7
        let stats = Stats(startedAt: "2026-09-22T00:00:00.000Z")
        let status = StatusResponse(
            node: "m5", identity: Identity(node: "m5", pubkey: "ab", fingerprint: "ab"), legacyAllowed: true,
            session: nil, invite: Invite(node: "m5", session: nil, socket: "/s", url: "http://m5:6750", hint: nil),
            topology: Topology(workspaces: [UiWorkspace(id: "w1")], tabs: [UiTab(id: "w1:t1", workspace: "w1")]),
            gossip: false, stats: stats, members: [member],
            messages: [FedMessage(id: "m5:1", node: "m5", seq: 1, from: "m5", text: "hi", at: "2026-09-22T00:00:00.000Z")],
            peers: [PeerView(name: "white", url: "http://white:6750")],
            peerMembers: ["white": [member]], peerUi: ["white": "http://white:6750"],
            known: [KnownNode(node: "far", url: nil, lastHeard: "2026-09-22T00:00:00.000Z")],
            relayed: ["far": RelayedPeer(via: "white", url: nil, members: [], ok: true, lastOkAt: nil, consecutive: 0)]
        )
        let bytes = try JSONCoding.encode(status)
        XCTAssertEqual(try JSONCoding.decode(StatusResponse.self, from: bytes), status)
        XCTAssertTrue(String(decoding: bytes, as: UTF8.self).hasPrefix("{\"node\":\"m5\",\"identity\":{\"node\":\"m5\",\"pubkey\":\"ab\",\"fingerprint\":\"ab\"},\"legacyAllowed\":true,\"session\":null,\"invite\":{"))

        let entry = AuditEntry(id: "a1", at: "t", action: .memberKick, node: "x", by: "m5", reason: nil, summary: "s",
                               steps: [AuditStep(n: 1, label: "l", wire: nil, ok: true, detail: "d")])
        XCTAssertEqual(try JSONCoding.decode(AuditEntry.self, from: try JSONCoding.encode(entry, pretty: true)), entry)
        XCTAssertEqual(String(decoding: try JSONCoding.encode(entry), as: UTF8.self),
                       "{\"id\":\"a1\",\"at\":\"t\",\"action\":\"member.kick\",\"node\":\"x\",\"by\":\"m5\",\"summary\":\"s\",\"steps\":[{\"n\":1,\"label\":\"l\",\"ok\":true,\"detail\":\"d\"}]}")
    }

    func testTopLevelScalarsAndEmptyValues() throws {
        XCTAssertEqual(try JSONStringify.string("a/b\"c"), "\"a/b\\\"c\"")
        XCTAssertEqual(try JSONStringify.string(42), "42")
        XCTAssertEqual(try JSONStringify.string(JSONValue.null), "null")
        XCTAssertEqual(try JSONStringify.string([String](), pretty: true), "[]")
        XCTAssertEqual(try JSONStringify.string(JSONValue.object([:]), pretty: true), "{}")
        XCTAssertEqual(try JSONStringify.string(["k": JSONValue.string("v")], pretty: true), "{\n  \"k\": \"v\"\n}")
    }
}

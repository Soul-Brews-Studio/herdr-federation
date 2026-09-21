import XCTest
@testable import FederationNode

/// The transport's failure text is part of the wire: it lands in `/api/calls`
/// and in the 502 body of `/api/pane/<id>`. Measured on Bun 1.3.14: node:net
/// under Bun reports `connect ENOENT <path>` for EVERY failed unix connect —
/// a path that does not exist, a bound socket nobody listens on (kernel
/// ECONNREFUSED), a `chmod 000` socket (EACCES), a plain file (ENOTSOCK).
/// Node 26 names the real errno; the fleet runs Bun.
final class HerdrClientTests: XCTestCase {
    /// `<wt>/swift-node/.tmp` — gitignored, and short enough for sun_path (104 bytes).
    private static let scratch: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent(".tmp")

    private var made: [String] = []
    override func tearDown() {
        for p in made { unlink(p) }
        made = []
        super.tearDown()
    }

    private func expectSocketError(_ client: SocketHerdrClient, _ message: String, file: StaticString = #filePath, line: UInt = #line) async {
        do {
            _ = try await client.call("pane.list", params: [:], timeoutMs: 2000)
            XCTFail("expected a throw", file: file, line: line)
        } catch let e as HerdrError {
            XCTAssertEqual(e.code, "socket", file: file, line: line)
            XCTAssertEqual(e.message, message, file: file, line: line)
            XCTAssertEqual(e.description, "Error: \(message)", file: file, line: line)
        } catch {
            XCTFail("wrong error: \(error)", file: file, line: line)
        }
        let calls = await client.calls()
        XCTAssertEqual(calls.first?.ok, false, file: file, line: line)
        XCTAssertEqual(calls.first?.error, message, file: file, line: line)
        XCTAssertEqual(calls.first?.cli, "herdr pane list", file: file, line: line)
    }

    func testMissingSocketReadsLikeBun() async {
        let path = Self.scratch.appendingPathComponent("hc-missing-\(String(UUID().uuidString.prefix(8))).sock").path
        await expectSocketError(SocketHerdrClient(socketPath: path), "connect ENOENT \(path)")
    }

    func testStaleSocketReadsLikeBunNotLikeTheKernel() throws {
        // bound and never listened on: the kernel answers ECONNREFUSED, Bun says ENOENT
        try FileManager.default.createDirectory(at: Self.scratch, withIntermediateDirectories: true)
        let path = Self.scratch.appendingPathComponent("hc-stale-\(String(UUID().uuidString.prefix(8))).sock").path
        made.append(path)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        XCTAssertGreaterThanOrEqual(fd, 0)
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        let capacity = MemoryLayout.size(ofValue: addr.sun_path)
        XCTAssertLessThan(bytes.count, capacity)
        withUnsafeMutablePointer(to: &addr.sun_path) { p in
            p.withMemoryRebound(to: CChar.self, capacity: capacity) { dst in
                for (i, b) in bytes.enumerated() { dst[i] = CChar(bitPattern: b) }
                dst[bytes.count] = 0
            }
        }
        let bound = withUnsafePointer(to: &addr) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        XCTAssertEqual(bound, 0)
        close(fd)

        let expectation = self.expectation(description: "call")
        Task {
            await expectSocketError(SocketHerdrClient(socketPath: path), "connect ENOENT \(path)")
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 10)
    }

    func testRequestTooLargeIsRejectedBeforeConnectingAndNotLogged() async {
        let client = SocketHerdrClient(socketPath: "/nowhere.sock")
        let huge = String(repeating: "x", count: Const.herdrMaxLineBytes)
        do {
            _ = try await client.call("pane.send_text", params: ["pane_id": .string("w1:p1"), "text": .string(huge)], timeoutMs: 1000)
            XCTFail("expected a throw")
        } catch let e as HerdrError {
            XCTAssertEqual(e.code, "request_too_large")
            XCTAssertEqual(e.message, "pane.send_text exceeds the 1 MiB request cap")
        } catch {
            XCTFail("wrong error: \(error)")
        }
        let calls = await client.calls()
        XCTAssertTrue(calls.isEmpty, "herdr.ts rejects before record()")
    }
}

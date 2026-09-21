import XCTest
@testable import FederationNode

/// A throwaway keypair Node generated for this test (never used by any node):
/// the PEM as `node:crypto` exports it and the raw pubkey hex identity.ts
/// derives from the SPKI DER. Loading it in Swift must give the same pubkey,
/// and a Swift signature must verify — that is the whole interop contract.
private let nodePEM = """
-----BEGIN PRIVATE KEY-----
MC4CAQAwBQYDK2VwBCIEIIb8YTiCp4FqJ6C90LkQujZp3tDhGkNr/ZUhdIqVhlC0
-----END PRIVATE KEY-----

"""
private let nodePubkey = "17f98a50d3110324560a83f49a50cc4fa94af3541f0b54acaf421a864315bc69"
/// `crypto.sign(null, msg, privateKey).toString("base64url")` over redeemMessage(tok, t, 2026-09-22T00:00:00.000Z)
private let nodeSignature = "Pxi8yuWpNbuxn4cMDbgbKJvf--eCmOQ2Nabo_BhszzQEDhWfHrTx2z7w3HQgJlYVtZRWiQ_NAx5iAaZ3ggtuCA"

final class IdentityTests: XCTestCase {
    func testSignVerifyRoundTrip() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("fed-ident-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let path = dir.appendingPathComponent(".fed-identity.json").path
        let a = try NodeIdentity.open(node: "t", path: path)
        let b = try NodeIdentity.open(node: "t", path: path)   // second open reloads, same key
        XCTAssertEqual(a.pubkey, b.pubkey)
        XCTAssertEqual(a.pubkey.count, 64)
        XCTAssertEqual(a.identity.fingerprint, String(a.pubkey.prefix(16)))

        let msg = redeemMessage(token: "tok", node: "t", at: "2026-09-22T00:00:00.000Z")
        let sig = a.sign(msg)
        XCTAssertTrue(verifySignature(message: msg, signature: sig, pubkeyHex: a.pubkey))
        XCTAssertFalse(verifySignature(message: msg + "x", signature: sig, pubkeyHex: a.pubkey))
        XCTAssertFalse(verifySignature(message: msg, signature: sig, pubkeyHex: "deadbeef"))
    }

    func testLoadsNodeWrittenPEM() throws {
        let key = try NodeIdentity.privateKey(fromPEM: nodePEM)
        XCTAssertEqual(key.rawRepresentation.count, 32)
        // the same pubkey identity.ts derived from the SPKI DER
        XCTAssertEqual(key.publicKey.rawRepresentation.hex(), nodePubkey)
        // re-export must reproduce Node's PEM byte for byte
        XCTAssertEqual(NodeIdentity.pem(for: key), nodePEM)
        // a Node signature verifies here. (CryptoKit's ed25519 signatures are
        // randomized while Node's follow RFC 8032 deterministically, so the bytes
        // differ per run — only verification is comparable, in both directions.)
        let msg = redeemMessage(token: "tok", node: "t", at: "2026-09-22T00:00:00.000Z")
        XCTAssertTrue(verifySignature(message: msg, signature: nodeSignature, pubkeyHex: nodePubkey))
        let mine = (try? key.signature(for: Data(msg.utf8)).base64url()) ?? ""
        XCTAssertTrue(verifySignature(message: msg, signature: mine, pubkeyHex: nodePubkey))
    }

    func testSecretShape() {
        let s = secret()
        XCTAssertEqual(s.count, 32)
        XCTAssertNil(s.firstIndex(of: "="))
        XCTAssertNotEqual(secret(), secret())
    }

    func testBase64urlAndHex() {
        XCTAssertEqual(Data([0xfb, 0xff]).base64url(), "-_8")
        XCTAssertEqual(Data(base64url: "-_8"), Data([0xfb, 0xff]))
        XCTAssertEqual(Data(hex: "00ff")?.hex(), "00ff")
        XCTAssertNil(Data(hex: "0"))
    }
}

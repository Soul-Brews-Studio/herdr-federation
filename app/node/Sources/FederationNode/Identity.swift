// Identity.swift — src/identity.ts.
//
// An ed25519 keypair generated once and kept forever, used exactly once per
// relationship (at redeem) to prove the joiner holds the key it claims. The
// pubkey is what a ban pins to.
//
// On disk: `.fed-identity.json` = `{ pubkey, privateKey, createdAt }` where
// `privateKey` is the PKCS#8 PEM Node wrote. The same file loads on both
// runtimes: PKCS#8 for ed25519 is a fixed 16-byte prefix and the 32 raw bytes.
//
// NEVER print, log, or return the private key or the PEM. A 200-byte head of
// this file is the whole key.

import Foundation
import CryptoKit

/// `302e020100300506032b657004220420` — PKCS#8 header for an ed25519 private key.
private let pkcs8Prefix = Data([0x30, 0x2e, 0x02, 0x01, 0x00, 0x30, 0x05, 0x06, 0x03, 0x2b, 0x65, 0x70, 0x04, 0x22, 0x04, 0x20])

public func fingerprint(_ pubkeyHex: String) -> String { String(pubkeyHex.prefix(Const.fingerprintChars)) }

/// The secret in an invite link, and the token a membership rides on: 24 random bytes, base64url.
///
/// The status is checked, not discarded: on a CSPRNG failure the buffer would
/// still hold its zero fill and this would hand back the constant base64url of
/// 24 zero bytes — as an invite secret AND as a member token. `randomBytes(24)`
/// throws in identity.ts, so failing loudly is also the parity behaviour.
public func secret() -> String {
    var bytes = [UInt8](repeating: 0, count: Const.secretBytes)
    guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
        fatalError("secret: CSPRNG failed")
    }
    return Data(bytes).base64url()
}

extension Data {
    /// Node's `base64url`: no padding, `-`/`_` alphabet.
    public func base64url() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    public init?(base64url s: String) {
        var b = s.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while b.count % 4 != 0 { b += "=" }
        self.init(base64Encoded: b)
    }

    public init?(hex: String) {
        guard hex.count % 2 == 0 else { return nil }
        var out = Data(capacity: hex.count / 2)
        var i = hex.startIndex
        while i < hex.endIndex {
            let j = hex.index(i, offsetBy: 2)
            guard let byte = UInt8(hex[i..<j], radix: 16) else { return nil }
            out.append(byte)
            i = j
        }
        self = out
    }

    public func hex() -> String { map { String(format: "%02x", $0) }.joined() }
}

public final class NodeIdentity: Sendable {
    public let node: String
    /// raw ed25519 public key, hex — the value ON DISK, not one re-derived from
    /// the PEM. identity.ts hands `saved.pubkey` straight to the constructor, so
    /// a file whose two halves disagree reports the same pubkey on both runtimes.
    public let pubkey: String
    /// the PKCS#8 PEM exactly as it sits in `.fed-identity.json`. Held as text,
    /// not as a parsed key, because `sign()` in identity.ts calls
    /// `createPrivateKey(this.privatePem)` per signature — the parse happens at
    /// sign time there, and a PEM that will not parse is a failed signature, NOT
    /// a reason to mint a new identity.
    private let privatePem: String

    private init(node: String, pubkey: String, privatePem: String) {
        self.node = node
        self.pubkey = pubkey
        self.privatePem = privatePem
    }

    private struct Saved: Codable {
        var pubkey: String
        var privateKey: String
        var createdAt: String?
    }

    /// Load the keypair from disk, or make one on first boot and persist it.
    ///
    /// BUN: `if (saved.privateKey && saved.pubkey) return new NodeIdentity(...)` —
    /// the stored record is accepted on TRUTHINESS alone, with no validation, and
    /// the file is rewritten only when reading or parsing the JSON threw. Anything
    /// stricter here would rotate the node's long-term key — the thing peers' bans
    /// pin to — behind an unrecoverable, non-atomic overwrite of a file that has
    /// no backup. Measured: a `.fed-identity.json` holding a non-PEM privateKey
    /// boots on Bun with the stored pubkey and leaves the file alone.
    public static func open(node: String, path: String) throws -> NodeIdentity {
        if let data = FileManager.default.contents(atPath: path),
           let saved = try? JSONCoding.decode(Saved.self, from: data),
           !saved.privateKey.isEmpty, !saved.pubkey.isEmpty {
            return NodeIdentity(node: node, pubkey: saved.pubkey, privatePem: saved.privateKey)
        }
        let key = Curve25519.Signing.PrivateKey()
        let pubkey = key.publicKey.rawRepresentation.hex()
        let privatePem = pem(for: key)
        let saved = Saved(pubkey: pubkey, privateKey: privatePem, createdAt: Stamp.iso())
        // BUN: `Bun.write(path, ...)` — a plain 0644 create, not atomic. Same here,
        // deliberately: five live nodes ship that file mode and the conformance
        // harness treats the pair as equivalent.
        try JSONCoding.encode(saved, pretty: true).write(to: URL(fileURLWithPath: path))
        return NodeIdentity(node: node, pubkey: pubkey, privatePem: privatePem)
    }

    public var identity: Identity { Identity(node: node, pubkey: pubkey, fingerprint: fingerprint(pubkey)) }

    /// ed25519 over the UTF-8 message, base64url — what `FedRedeemRequest.sig` carries.
    /// A PEM that will not parse is an empty signature (which fails verification
    /// at the far end), matching identity.ts's throw-at-sign-time shape rather
    /// than turning a bad file into a new key.
    public func sign(_ message: String) -> String {
        guard let key = try? Self.privateKey(fromPEM: privatePem) else { return "" }
        return (try? key.signature(for: Data(message.utf8)).base64url()) ?? ""
    }

    // MARK: PEM ↔ CryptoKit

    static func privateKey(fromPEM pem: String) throws -> Curve25519.Signing.PrivateKey {
        let body = pem
            .components(separatedBy: .newlines)
            .filter { !$0.hasPrefix("-----") }
            .joined()
        guard let der = Data(base64Encoded: body), der.count >= 32 else {
            throw NodeError("identity: not a PEM private key")
        }
        // PKCS#8 ed25519 is prefix + 32 raw bytes; the raw key is the tail either way
        return try Curve25519.Signing.PrivateKey(rawRepresentation: der.suffix(32))
    }

    /// `privateKey.export({ type: "pkcs8", format: "pem" })` — 64-column body, trailing newline.
    static func pem(for key: Curve25519.Signing.PrivateKey) -> String {
        let der = pkcs8Prefix + key.rawRepresentation
        let b64 = der.base64EncodedString()
        var lines: [String] = []
        var i = b64.startIndex
        while i < b64.endIndex {
            let j = b64.index(i, offsetBy: 64, limitedBy: b64.endIndex) ?? b64.endIndex
            lines.append(String(b64[i..<j]))
            i = j
        }
        return "-----BEGIN PRIVATE KEY-----\n" + lines.joined(separator: "\n") + "\n-----END PRIVATE KEY-----\n"
    }
}

/// Verify a signature against a peer's raw hex pubkey. Never throws — a malformed key is just false.
public func verifySignature(message: String, signature: String, pubkeyHex: String) -> Bool {
    guard let raw = Data(hex: pubkeyHex), raw.count == 32,
          let sig = Data(base64url: signature),
          let key = try? Curve25519.Signing.PublicKey(rawRepresentation: raw)
    else { return false }
    return key.isValidSignature(sig, for: Data(message.utf8))
}

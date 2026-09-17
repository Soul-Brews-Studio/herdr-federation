// The wire, as much of it as a tray needs.
//
// Every field is Optional that the server may omit, because this tray is
// expected to point at a node older or newer than itself: a node that predates
// `identity` must still render, showing what it does have rather than nothing.
// Decoding is the one place a version skew turns into a blank menu, so it is the
// one place to be forgiving.

import Foundation

struct Identity: Decodable {
    var node: String?
    var pubkey: String?
    var fingerprint: String?
}

/// Lifetime totals — history, not health. `pushed`/`pullOk` count requests while
/// `pulled` counts messages ingested, so they are different units and `pulled` is
/// legitimately 0 whenever peers have nothing new. Read `PeerView.consecutive`
/// for whether a link is working right now.
struct Stats: Decodable {
    var pushed: Int?
    var pushErrors: Int?
    var pullOk: Int?
    var pullErrors: Int?
    var pulled: Int?
    var errors: Int?
    /// lifetime payload bytes on the wire — bodies only, no headers
    var bytesOut: Int?
    var bytesIn: Int?
    var startedAt: String?
}

struct PeerView: Decodable {
    var name: String
    var url: String
    var via: String?
    var ok: Bool?
    var lastError: String?
    var lastErrorAt: String?
    var lastSeen: String?
    var lastOkAt: String?
    /// Failed attempts since the last success. 0 = fine right now.
    var consecutive: Int?
}

struct Pane: Decodable {
    var handle: String
    var pane: String
    /// the agent herdr detected, or "shell" when it found none — a bare shell is
    /// a pane, not an agent, and the fleet bar counts them apart
    var kind: String?
    var status: String?
    var workspaceLabel: String?
    var repo: String?
}

struct Invite: Decodable {
    var node: String?
    var url: String?
    var hint: String?
}

/// GET /api/status
struct NodeStatus: Decodable {
    var node: String
    var identity: Identity?
    var legacyAllowed: Bool?
    var session: String?
    var invite: Invite?
    var stats: Stats?
    var members: [Pane]?
    var peers: [PeerView]?
    var peerMembers: [String: [Pane]]?
}

struct MemberRecord: Decodable {
    var node: String
    var pubkey: String?
    var fingerprint: String?
    var url: String?
    var joinedAt: String?
    var viaInvite: String?
    var lastSeen: String?
    var legacy: Bool?
}

struct BanRecord: Decodable {
    var node: String
    var pubkey: String?
    var at: String?
    var by: String?
    var reason: String?
}

struct InviteLink: Decodable {
    var id: String
    var token: String?
    var url: String?
    var createdAt: String?
    var expiresAt: String?
    var maxUses: Int?
    var uses: Int
    var note: String?
    var status: String
    var usedBy: [Used]?

    struct Used: Decodable {
        var node: String
        var at: String
    }
}

struct AuditEntry: Decodable {
    var id: String
    var at: String
    var action: String
    var node: String
    var by: String?
    var reason: String?
    var summary: String?
    var steps: [Step]?

    struct Step: Decodable {
        var n: Int
        var label: String
        var ok: Bool
        var detail: String?
        var wire: String?
    }

    var failed: Bool { (steps ?? []).contains { !$0.ok } }
}

/// GET /api/admin
struct AdminState: Decodable {
    var node: String
    var identity: Identity?
    var legacyAllowed: Bool?
    var members: [MemberRecord]?
    var invites: [InviteLink]?
    var bans: [BanRecord]?
    var audit: [AuditEntry]?
    var meshMembers: [String: [MemberRecord]]?
}

struct ErrorReply: Decodable { var error: String? }

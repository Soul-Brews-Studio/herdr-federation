import Foundation

/**
 One word, computed from LOCAL facts only.

 Nothing from `peerMembers`, `meshMembers` or `known` may move this chip. Those
 describe what the mesh reports about itself, arriving on the last successful
 pull — a stale cache can claim anything, and enforcement here is local-only
 anyway. A verdict that turns red because a peer said something is a verdict you
 cannot act on.
 */
enum Level: Int, Comparable {
    case healthy, degraded, down, none
    static func < (a: Level, b: Level) -> Bool { a.rawValue < b.rawValue }

    var word: String {
        switch self {
        case .healthy: return "HEALTHY"
        case .degraded: return "DEGRADED"
        case .down: return "LINK DOWN"
        case .none: return "NO PEERS"
        }
    }

    /// Carries the same meaning without colour, for anyone who cannot use it.
    var glyph: String {
        switch self {
        case .healthy: return "●"
        case .degraded: return "▲"
        case .down: return "✕"
        case .none: return "○"
        }
    }
}

struct Verdict {
    var level: Level
    var detail: String
    /// the peer the alarm is about, when there is one
    var peer: PeerView?

    static func of(status: NodeStatus?, admin: AdminState?, push: Series, pull: Series, offline: String?) -> Verdict {
        if let offline { return Verdict(level: .down, detail: "this node: \(offline)", peer: nil) }
        guard let status else { return Verdict(level: .down, detail: "no reply", peer: nil) }

        let peers = status.peers ?? []
        if peers.isEmpty {
            // Honest: not healthy, just nothing to be healthy about.
            return Verdict(level: .none, detail: "no peers — create an invite", peer: nil)
        }

        let failing = peers.filter { ($0.consecutive ?? 0) >= 3 }
        if let worst = failing.max(by: { ($0.consecutive ?? 0) < ($1.consecutive ?? 0) }) {
            return Verdict(level: .down,
                           detail: "\(worst.name) failing · \(worst.consecutive ?? 0) in a row",
                           peer: worst)
        }

        let wobbling = peers.filter { (1...2).contains($0.consecutive ?? 0) }
        if let w = wobbling.first {
            return Verdict(level: .degraded, detail: "\(w.name) · \(w.consecutive ?? 0) failed, retrying", peer: w)
        }
        if push.errors > 0 || pull.errors > 0 {
            return Verdict(level: .degraded,
                           detail: "\(push.errors + pull.errors) error\(push.errors + pull.errors == 1 ? "" : "s") in the last 5 min",
                           peer: nil)
        }
        if status.legacyAllowed == true {
            // A kick does not fully close the door while this is on, so it is not
            // a healthy state even when every link is up.
            return Verdict(level: .degraded, detail: "FED_ALLOW_LEGACY is on — untokened peers accepted", peer: nil)
        }
        if let bad = admin?.audit?.first, bad.failed {
            return Verdict(level: .degraded, detail: "last action failed · \(bad.action) \(bad.node)", peer: nil)
        }
        return Verdict(level: .healthy, detail: "", peer: nil)
    }
}

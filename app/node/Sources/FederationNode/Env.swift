// Env.swift — the environment the Bun node reads at the top of server.ts, and
// the two derived facts every module asks about: where peers reach us, and
// whether something is already serving our port.

import Foundation

/// `Number(env ?? fallback)` for the three numeric env vars server.ts reads.
///
/// An UNSET variable takes the fallback (the `?? 6750` half). A set one goes
/// through JS `Number()`: whitespace-trimmed, `""` → 0, otherwise a decimal
/// parse, and NaN for anything that is not a number.
///
/// DIVERGENCE, documented: a NaN result falls back to the default here. Bun
/// hands NaN straight to `Bun.serve({ port: NaN })` / `setInterval(…, NaN)` and
/// what those do was not measured, so this refuses to guess rather than invent a
/// behaviour. 0 and a trailing-whitespace number — the two reachable cases —
/// now match.
func jsEnvNumber(_ raw: String?, default fallback: Int) -> Int {
    guard let raw else { return fallback }
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.isEmpty { return 0 }
    guard let n = Double(trimmed), n.isFinite else { return fallback }
    return Int(n)
}

public struct NodeEnv: Sendable {
    /// the checkout root — `join(import.meta.dir, "..")` in server.ts
    public var root: String
    public var configPath: String      // FED_CONFIG    ?? <root>/peers.json
    public var statePath: String       // FED_STATE     ?? <root>/.fed-state.json
    public var identityPath: String    // FED_IDENTITY  ?? <root>/.fed-identity.json
    public var membersPath: String     // FED_MEMBERS   ?? <root>/.fed-members.json
    public var dist: String            // <root>/web/dist
    public var port: Int               // FED_PORT      ?? 6750
    public var host: String            // FED_HOST      ?? 127.0.0.1
    public var syncMs: Int             // FED_SYNC_MS   ?? 2000
    public var paneMs: Int             // FED_PANE_MS   ?? 300
    /// `(FED_ALLOW_LEGACY ?? "1") !== "0"` — on unless explicitly "0"
    public var allowLegacy: Bool
    public var advertise: String?      // FED_ADVERTISE
    public var herdrSession: String?   // HERDR_SESSION
    public var socketPath: String      // HERDR_SOCKET_PATH ?? $HOME/.config/herdr/herdr.sock
    /// FED_LOG ?? "access", lowercased
    public var log: String

    public var logOn: Bool { log != "off" && log != "0" }
    public var logDebug: Bool { log == "debug" }

    public init(root: String, environment env: [String: String] = ProcessInfo.processInfo.environment) {
        self.root = root
        let home = env["HOME"] ?? NSHomeDirectory()
        configPath = env["FED_CONFIG"] ?? root + "/peers.json"
        statePath = env["FED_STATE"] ?? root + "/.fed-state.json"
        identityPath = env["FED_IDENTITY"] ?? root + "/.fed-identity.json"
        membersPath = env["FED_MEMBERS"] ?? root + "/.fed-members.json"
        dist = root + "/web/dist"
        // `Number(process.env.FED_PORT ?? 6750)`, not `parseInt`: JS trims
        // surrounding whitespace, reads an EMPTY string as 0 (so `FED_PORT=`
        // exported-but-empty binds an ephemeral port under Bun, not 6750), and
        // gives NaN for anything else. `Int(...)` accepted none of that — a
        // `FED_PORT="6751 "` bound 6750 here and 6751 there, which is precisely
        // the collision the port guard exists to prevent.
        port = jsEnvNumber(env["FED_PORT"], default: Const.defaultPort)
        host = env["FED_HOST"] ?? Const.defaultHost
        syncMs = jsEnvNumber(env["FED_SYNC_MS"], default: Const.syncMs)
        paneMs = jsEnvNumber(env["FED_PANE_MS"], default: Const.paneMs)
        allowLegacy = (env["FED_ALLOW_LEGACY"] ?? "1") != "0"
        advertise = env["FED_ADVERTISE"]
        herdrSession = env["HERDR_SESSION"]
        socketPath = env["HERDR_SOCKET_PATH"] ?? home + "/.config/herdr/herdr.sock"
        log = (env["FED_LOG"] ?? "access").lowercased()
    }

    /// How peers reach us. 0.0.0.0 means "bound everywhere", which is not an address.
    public func publicBase() -> String? {
        if let a = advertise, !a.isEmpty { return "http://\(a):\(port)" }
        if host == "127.0.0.1" || host == "0.0.0.0" || host == "localhost" { return nil }
        return "http://\(host):\(port)"
    }

    /// The address the port guard probes: our own host, or loopback when bound everywhere.
    public var probeHost: String { host == "0.0.0.0" ? "127.0.0.1" : host }
}

/// The port guard. Bun does not fail on a second bind, so two nodes end up
/// sharing a port and requests land on whichever accepted them. The Swift node
/// would fail the bind, but it keeps the probe so the message — and the exit
/// code 3 — are the same on both runtimes.
///
/// Returns the node name already serving there, `""` when something answered
/// 200 without a `node`, or nil when nothing of ours is listening.
public func probeExistingNode(env: NodeEnv) async -> String? {
    guard let url = URL(string: "http://\(env.probeHost):\(env.port)/api/status") else { return nil }
    var req = URLRequest(url: url, timeoutInterval: Double(Const.portProbeMs) / 1000)
    req.httpMethod = "GET"
    do {
        // a wall-clock deadline, like the probe's own AbortSignal.timeout(700)
        let (data, resp) = try await fetchWithDeadline(req, timeoutMs: Const.portProbeMs)
        guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { return nil }
        let who = try? JSONCoding.decode(JSONValue.self, from: data)
        return who?["node"]?.stringValue ?? "?"
    } catch {
        return nil
    }
}

/// The lines the Bun node prints before `process.exit(3)`.
public func portGuardMessage(env: NodeEnv, servingNode: String) -> [String] {
    [
        "[fed] port \(env.port) is already serving node \"\(servingNode)\" — refusing to start a second one.",
        "[fed] Bun will share the socket rather than fail, and then your calls land on whichever process accepts them.",
        // BUN: server.ts:270 hardcodes 6751 — the line is wrong on any port but
        // the default (a node refused on 6762 is told to use 6751), and it is
        // what five live nodes print, so it is what this one prints.
        "[fed]   use another port:  FED_PORT=6751 ...",
        "[fed]   or stop that one:  just node stop",
    ]
}

// Env.swift — the environment the Bun node reads at the top of server.ts, and
// the two derived facts every module asks about: where peers reach us, and
// whether something is already serving our port.

import Foundation

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
        port = Int(env["FED_PORT"] ?? "") ?? Const.defaultPort
        host = env["FED_HOST"] ?? Const.defaultHost
        syncMs = Int(env["FED_SYNC_MS"] ?? "") ?? Const.syncMs
        paneMs = Int(env["FED_PANE_MS"] ?? "") ?? Const.paneMs
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
        let (data, resp) = try await URLSession.shared.data(for: req)
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
        "[fed]   use another port:  FED_PORT=\(env.port + 1) ...",
        "[fed]   or stop that one:  just node stop",
    ]
}

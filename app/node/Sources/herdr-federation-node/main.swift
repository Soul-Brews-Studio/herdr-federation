// main.swift — src/server.ts lines 28–62 (boot) and 857–869 (serve + sync loop).
//
// The Bun node does all of this at module scope with top-level await. Order is
// load-bearing and reproduced exactly:
//
//   1. peers.json  (a missing file is fatal — `await Bun.file(CONFIG_PATH).json()` throws)
//   2. NodeIdentity.open
//   3. Members(...).load()
//   4. Federation(config, STATE_PATH, tokenFor), advertised = publicBase(), load()
//   5. adoptLegacy for every configured peer
//   6. the port guard (probe /api/status, exit 3 if one of ours answers)
//   7. serve
//   8. await sync() once, then setInterval(sync, SYNC_MS)
//   9. the three `[fed] ...` banner lines
//
// BUN: the banner prints AFTER the first sync (`await sync()` sits above the
// three console.log lines) but the PORT IS ALREADY OPEN by then, because
// Bun.serve() is line 833. Both facts are kept here via onServerRunning.

import Foundation
import FederationNode
import Hummingbird
import HummingbirdWebSocket
import Logging
import NIOCore

// Bun/Node flush stdout per line even when it is a file or a pipe. C stdio
// block-buffers a redirected stdout, so `just swift run > node.log` and the
// launchd StandardOutPath showed NOTHING until 4 KiB of access lines had piled
// up — the log looked dead while the node was serving. Line-buffer it to match.
setvbuf(stdout, nil, _IOLBF, 0)

// MARK: - the checkout root

/// server.ts derives ROOT from `import.meta.dir` — the directory holding the
/// sources. There is no such thing in a compiled binary, so: walk up from the
/// executable looking for `src/server.ts`, and fall back to the working
/// directory (which is what `just swift run` and smoke.sh give us).
func findRoot() -> String {
    let fm = FileManager.default
    func holdsCheckout(_ dir: String) -> Bool {
        fm.fileExists(atPath: dir + "/src/server.ts")
    }

    var candidates: [String] = []
    if let exe = Bundle.main.executablePath {
        candidates.append(URL(fileURLWithPath: exe).resolvingSymlinksInPath().deletingLastPathComponent().path)
    }
    candidates.append(fm.currentDirectoryPath)

    for start in candidates {
        var dir = URL(fileURLWithPath: start, isDirectory: true).standardized
        while true {
            if holdsCheckout(dir.path) { return dir.path }
            let parent = dir.deletingLastPathComponent()
            if parent.path == dir.path { break }
            dir = parent
        }
    }
    return fm.currentDirectoryPath
}

func die(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

// MARK: - boot

let env = NodeEnv(root: findRoot())

// 1. peers.json. BUN: `await Bun.file(CONFIG_PATH).json()` rejects at module
//    scope on a missing or malformed file and Bun exits 1 with the error.
guard let configData = FileManager.default.contents(atPath: env.configPath) else {
    die("[fed] cannot read \(env.configPath): no such file")
}
let config: FedConfig
do {
    config = try JSONCoding.decode(FedConfig.self, from: configData)
} catch {
    die("[fed] cannot parse \(env.configPath): \(error)")
}

// 2. identity
let ident: NodeIdentity
do {
    ident = try NodeIdentity.open(node: config.node, path: env.identityPath)
} catch {
    die("[fed] cannot open identity at \(env.identityPath): \(error)")
}

let publicBase = env.publicBase()

// 3. membership store
let fedMembers = Members(
    node: config.node,
    statePath: env.membersPath,
    baseUrl: { publicBase },
    allowLegacy: env.allowLegacy
)
await fedMembers.load()

// 4. federation
let fed = Federation(
    config: config,
    statePath: env.statePath,
    tokenFor: { node in await fedMembers.tokenFor(node) }
)
await fed.setAdvertised(publicBase)
await fed.load()

// 5. peers configured before tokens existed: show them, flagged, rather than hide them
for p in await fed.peers() {
    await fedMembers.adoptLegacy(node: p.name, url: p.url)
}

// 6. the port guard
if let who = await probeExistingNode(env: env) {
    for line in portGuardMessage(env: env, servingNode: who) {
        FileHandle.standardError.write(Data((line + "\n").utf8))
    }
    exit(3)
}

// 7. wire it together
let log = AccessLog(env: env)
let herdrClient = SocketHerdrClient(socketPath: env.socketPath)
let paneStreams = PaneStreams(herdr: herdrClient, paneMs: env.paneMs, log: log)

let runtime = NodeRuntime(
    env: env,
    config: config,
    ident: ident,
    members: fedMembers,
    fed: fed,
    herdr: herdrClient,
    nudger: paneStreams,
    log: log
)

var hbLogger = Logger(label: "herdr-federation-node")
// Hummingbird's own request logging would double every access line; the node's
// access log is AccessLogMiddleware.
hbLogger.logLevel = .warning

/// The `setInterval` handle, module scope exactly as in server.ts.
final class SyncLoop: @unchecked Sendable {
    private let lock = NSLock()
    private var task: Task<Void, Never>?
    func start(_ t: Task<Void, Never>) { lock.withLock { task = t } }
    func cancel() { lock.withLock { task?.cancel(); task = nil } }
}
let syncLoop = SyncLoop()

/// 8 and 9, and they run AFTER the bind and BESIDE the serving loop.
///
/// In server.ts `Bun.serve()` is line 833 and `await sync()` is 857, so the Bun
/// node is already answering requests while the first sync runs — a cold
/// /api/status during that window returns 200 with an empty roster.
///
/// Hummingbird awaits `onServerRunning` BEFORE it starts accepting child
/// channels (HummingbirdCore/Server/Server.swift: the callback is awaited above
/// the `executeThenClose` accept loop), so doing the work INSIDE this closure
/// bound the listen socket and then answered nothing for as long as the first
/// sync took — one herdr timeout plus one peer timeout, ~10 s on the fleet's
/// normal state, after every restart. That is the exact opposite of the parity
/// this was meant to keep. The whole thing is therefore spawned, not awaited:
/// the closure returns immediately and the accept loop starts.
@Sendable func afterBind(_ channel: any Channel) async {
    syncLoop.start(Task {
        // `await sync()`
        await runtime.sync()

        // the three banner lines, in server.ts's order and wording. BUN: they
        // print AFTER the first sync — the difference is that the port is
        // already open by now on both runtimes, not only on Bun.
        let peerNames = await fed.peers().map(\.name).joined(separator: ",")
        print("[fed] node=\(config.node) peers=\(peerNames.isEmpty ? "none" : peerNames) gossip=\(config.gossip ?? false)")
        print("[fed] herdr socket \(env.socketPath)")
        print("[fed] console http://\(env.host):\(env.port)")

        // `setInterval(sync, SYNC_MS)`. setInterval does NOT await its async
        // callback, so a sync slower than SYNC_MS overlaps the next one — with a
        // blackholed peer (5 s AbortSignal) and SYNC_MS = 2000 there are 2-3 in
        // flight, and `stats.pullOk` / `pushed` climb that much faster. Awaiting
        // each tick made those counters, which are part of the conformance
        // surface, diverge; each tick is fired unstructured instead.
        let period = Duration.milliseconds(env.syncMs)
        var next = ContinuousClock.now.advanced(by: period)
        while !Task.isCancelled {
            try? await Task.sleep(until: next, clock: .continuous)
            if Task.isCancelled { break }
            Task { await runtime.sync() }
            next = next.advanced(by: period)
            let now = ContinuousClock.now
            if next < now { next = now }
        }
    })

}

let app = Application(
    router: buildRouter(runtime),
    server: .http1WebSocketUpgrade(
        webSocketRouter: paneStreams.webSocketRouter(),
        configuration: .init(
            // Bun's `idleTimeout: 120`. Covers the pre-upgrade HTTP connection
            // only; after the upgrade the socket is held by autoPing.
            http1: .init(idleTimeout: .seconds(Int64(Const.wsIdleTimeoutSeconds))),
            ws: .init()
        )
    ),
    configuration: .init(
        address: .hostname(env.host, port: env.port)
        // NO serverName: a non-nil one makes Hummingbird stamp `server: …` on
        // every response, and `Bun.serve` sends no Server header at all. The
        // only headers server.ts ever adds are content-type and the
        // access-control-allow-origin on the invite-preview pair.
    ),
    onServerRunning: afterBind,
    logger: hbLogger
)

// runService installs SIGINT/SIGTERM graceful shutdown for us.
do {
    try await app.runService()
} catch {
    syncLoop.cancel()
    die("[fed] \(error)")
}
syncLoop.cancel()

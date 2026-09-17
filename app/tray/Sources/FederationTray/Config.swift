// Config: ~/.config/herdr-federation/tray.json
//
// {
//   "current": "m5",
//   "nodes": [
//     { "name": "m5",    "url": "http://127.0.0.1:6750" },
//     { "name": "white", "url": "http://100.97.212.120:6750" }
//   ],
//   "repoDir": "/path/to/herdr-federation"   // optional; start/stop shells out here
// }
//
// A missing file is written with defaults on first launch. Every key added after
// the first release stays Optional, because load() rewrites the file with
// defaults whenever decoding fails — a required key would silently discard a
// node list somebody typed by hand. Same trap the Structor tray documents.

import Foundation

struct Node: Codable, Equatable {
    var name: String
    var url: String
}

struct Config: Codable {
    var current: String
    var nodes: [Node]
    var repoDir: String?

    static var path: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/herdr-federation/tray.json")
    }

    /// The repo this tray drives, for `just node start|stop`. In order: the
    /// configured repoDir; `FederationAppDir` stamped into the bundle's
    /// Info.plist by bundle-tray.sh (the only thing that works from
    /// /Applications); the directory above `app/tray` when running out of the
    /// SwiftPM build tree.
    var repo: URL? {
        if let d = repoDir, !d.isEmpty {
            return URL(fileURLWithPath: (d as NSString).expandingTildeInPath)
        }
        if let d = Bundle.main.object(forInfoDictionaryKey: "FederationAppDir") as? String, !d.isEmpty {
            return URL(fileURLWithPath: d).deletingLastPathComponent()
        }
        let exe = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
        var d = exe.deletingLastPathComponent()
        // .build/release/FederationTray -> app/tray -> app -> repo
        for _ in 0..<5 {
            if FileManager.default.fileExists(atPath: d.appendingPathComponent("src/server.ts").path) { return d }
            d = d.deletingLastPathComponent()
        }
        return nil
    }

    static let fallback = Config(
        current: "local",
        nodes: [Node(name: "local", url: "http://127.0.0.1:6750")],
        repoDir: nil
    )

    static func load() -> Config {
        guard let data = try? Data(contentsOf: path),
              let c = try? JSONDecoder().decode(Config.self, from: data),
              !c.nodes.isEmpty
        else {
            fallback.save()
            return fallback
        }
        return c
    }

    func save() {
        let dir = Config.path.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? enc.encode(self).write(to: Config.path)
    }

    var node: Node { nodes.first { $0.name == current } ?? nodes[0] }
}

// AccessLog.swift — server.ts `access()`, `clock()`, and the LOG flags.
//
// On by default. `FED_LOG=off` silences it, `debug` adds the response
// content-type and every WebSocket open and close. Status first and fixed
// width: a wall of these is read by scanning one column.

import Foundation

public struct AccessLog: Sendable {
    public let on: Bool
    public let debug: Bool

    public init(env: NodeEnv) {
        on = env.logOn
        debug = env.logDebug
    }

    public init(on: Bool, debug: Bool) {
        self.on = on
        self.debug = debug
    }

    /// `[HH:MM:SS] 200 GET  /api/status                          12ms`
    /// `extra` is the ` <content-type>` suffix in debug mode, empty otherwise.
    public func line(method: String, path: String, status: Int, ms: Int, extra: String = "") -> String {
        "[\(Stamp.hms())] \(pad(String(status), 3)) \(pad(method, 4)) \(pad(path, 34)) \(padLeft("\(ms)ms", 6))\(extra)"
    }

    public func record(method: String, path: String, status: Int, ms: Int, contentType: String?) {
        guard on else { return }
        let extra = debug ? " \(contentType?.split(separator: ";").first.map(String.init) ?? "")" : ""
        print(line(method: method, path: path, status: status, ms: ms, extra: extra))
    }

    /// `[HH:MM:SS] WS   open <pane>` — debug only.
    public func socket(_ event: String, pane: String) {
        guard on, debug else { return }
        print("[\(Stamp.hms())] WS   \(event) \(pane)")
    }

    private func pad(_ s: String, _ n: Int) -> String {
        s.count >= n ? s : s + String(repeating: " ", count: n - s.count)
    }
    private func padLeft(_ s: String, _ n: Int) -> String {
        s.count >= n ? s : String(repeating: " ", count: n - s.count) + s
    }
}

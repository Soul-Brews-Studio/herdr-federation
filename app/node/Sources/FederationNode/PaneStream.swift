// PaneStream.swift — the `/ws/pane/<id>` route and the WS_HANDLERS block of
// src/server.ts.
//
// One socket per viewer, one poll per socket, one shared watcher map so that a
// send into a pane refreshes every viewer of that pane at once instead of
// waiting out the next tick.
//
// The read is ALWAYS `visible`. A `recent` read asks herdr for scrollback, and
// on an idle agent herdr gathers it by driving the pane's own mouse-scroll —
// the operator watches their terminal scroll up and snap back, once per read
// (a 400-line `recent` text read measured 13.8s). `visible` is the rendered
// viewport, immune by construction, at the cost of a `revision` that never
// moves: the diff is on the text itself.

import Foundation
import Hummingbird
import HummingbirdWebSocket
import NIOCore

// MARK: - one viewer

/// `PaneSocket` in server.ts: the pane, the format, the last text we sent, and
/// the push that compares them.
private actor PaneWatcher {
    let paneId: String
    let format: String
    private let herdr: any HerdrClient
    private let outbound: WebSocketOutboundWriter
    /// `ws.data.last` — nil means "send the next frame whatever it says"
    private var last: String?
    private var closed = false
    private var pushing = false
    private var pending = false

    init(paneId: String, format: String, herdr: any HerdrClient, outbound: WebSocketOutboundWriter) {
        self.paneId = paneId
        self.format = format
        self.herdr = herdr
        self.outbound = outbound
    }

    func clearLast() { last = nil }
    func close() { closed = true }

    /// `ws.data.last = undefined; void ws.data.push?.()` — what nudge() does to
    /// every watcher of a pane.
    func nudge() async {
        last = nil
        await push()
    }

    /// The Bun node hands `push` to `setInterval`, so a read slower than the
    /// interval overlaps the next one. Here a push already in flight absorbs the
    /// request and runs exactly once more when it lands: never two reads of the
    /// same pane at once, and never a dropped nudge.
    func push() async {
        if closed { return }
        if pushing {
            pending = true
            return
        }
        pushing = true
        defer { pushing = false }
        repeat {
            pending = false
            await pushOnce()
        } while pending && !closed
    }

    private func pushOnce() async {
        do {
            let read = try await herdr.readPane(paneId, source: Const.herdrDefaultSource, lines: .number(Double(Const.paneStreamLines)), format: format)
            let text = read.text ?? ""   // `read.text ?? ""`
            if text == last { return }
            last = text
            try await send(PaneFrame(text: text, revision: read.revision))
        } catch {
            try? await send(PaneErrorMessage(error: jsErrorString(error)))
        }
    }

    /// `ws.send(JSON.stringify(...))`. Written as a message rather than a single
    /// frame: a 200-line ansi read can pass the 16 KiB frame size, and a
    /// fragmented message is the same message to any client.
    func send<T: Encodable>(_ message: T) async throws {
        let data = try JSONCoding.encode(message)
        try await outbound.writeTextMessage(String(decoding: data, as: UTF8.self))
    }
}

/// `String(err)` in the Bun handler — the text that reaches the browser.
/// The three errors this node throws all print `Error: <message>`, which is what
/// `String(err)` gives for a JS Error. Anything else prints itself; a Swift
/// decode failure does not read like the `SyntaxError: ...` Bun would have sent.
/// (Not written as one cast to `CustomStringConvertible`: every Error satisfies
/// that through NSError bridging, and the bridged text is worse than "\(error)".)
private func jsErrorString(_ error: Error) -> String {
    if let herdr = error as? HerdrError { return herdr.description }
    if let node = error as? NodeError { return node.description }
    if let federation = error as? FederationError { return federation.description }
    return "\(error)"
}

// MARK: - who is watching what

/// `const watchers = new Map<string, Set<PaneWS>>()`.
private actor PaneWatchers {
    private var byPane: [String: [ObjectIdentifier: PaneWatcher]] = [:]

    func add(_ watcher: PaneWatcher, pane: String) {
        byPane[pane, default: [:]][ObjectIdentifier(watcher)] = watcher
    }

    func remove(_ watcher: PaneWatcher, pane: String) {
        byPane[pane]?.removeValue(forKey: ObjectIdentifier(watcher))
        if byPane[pane]?.isEmpty == true { byPane.removeValue(forKey: pane) }
    }

    func watching(_ pane: String) -> [PaneWatcher] {
        guard let set = byPane[pane] else { return [] }
        return Array(set.values)
    }
}

// MARK: - the route

public final class PaneStreams: PaneNudger {
    private let herdr: any HerdrClient
    private let paneMs: Int
    private let log: AccessLog
    private let watchers = PaneWatchers()

    /// A client message is small; the cap only exists so a fragmented one cannot
    /// grow without bound. A single inbound FRAME is still capped by
    /// `WebSocketServerConfiguration.maxFrameSize` (16 KiB by default).
    private static let maxInboundMessage = 1 << 20

    public init(herdr: any HerdrClient, paneMs: Int, log: AccessLog) {
        self.herdr = herdr
        self.paneMs = paneMs
        self.log = log
    }

    /// After we type into a pane, push a frame now instead of waiting for the
    /// next tick. Not awaited in the Bun node either (`void ws.data.push?.()`),
    /// so the caller's response is never behind a herdr read.
    public func nudge(_ paneId: String) async {
        for watcher in await watchers.watching(paneId) {
            Task { await watcher.nudge() }
        }
    }

    /// `/^[A-Za-z0-9_:-]+$/` — panes are addressed as `wD:p4`; anything else is
    /// not ours to open.
    public static func validPane(_ id: String) -> Bool {
        id.range(of: Const.paneIdPattern, options: .regularExpression) != nil
    }

    /// `decodeURIComponent(path.slice("/ws/pane/".length))`. Taken off the path
    /// rather than out of `{id}` so an id with a slash behaves as it does in Bun
    /// (it stays whole, then fails validPane). Hummingbird does not
    /// percent-decode path parameters; a malformed escape is left as written,
    /// where `decodeURIComponent` would have thrown.
    public static func paneId(from request: Request) -> String {
        let prefix = "/ws/pane/"
        let path = request.uri.path
        guard path.hasPrefix(prefix) else { return "" }
        let raw = String(path.dropFirst(prefix.count))
        return raw.removingPercentEncoding ?? raw
    }

    /// Mount this on the Application as the WebSocket router:
    /// `server: .http1WebSocketUpgrade(webSocketRouter: streams.webSocketRouter(), configuration: ...)`.
    /// A request this router declines falls through to the HTTP router, which is
    /// where `400 bad pane` and `426 expected a websocket` come from.
    public func webSocketRouter() -> Router<BasicWebSocketRequestContext> {
        let router = Router(context: BasicWebSocketRequestContext.self)
        router.ws(
            "/ws/pane/{id}",
            shouldUpgrade: { request, _ in
                Self.validPane(Self.paneId(from: request)) ? .upgrade() : .dontUpgrade
            },
            onUpgrade: { [self] inbound, outbound, context in
                await serve(inbound: inbound, outbound: outbound, request: context.request)
            }
        )
        return router
    }

    private func serve(inbound: WebSocketInboundStream, outbound: WebSocketOutboundWriter, request: Request) async {
        let paneId = Self.paneId(from: request)
        // `url.searchParams.get("format") === "ansi" ? "ansi" : "text"`
        let format = request.uri.queryParameters["format"] == "ansi" ? "ansi" : "text"

        let watcher = PaneWatcher(paneId: paneId, format: format, herdr: herdr, outbound: outbound)
        await watchers.add(watcher, pane: paneId)
        log.socket("open", pane: paneId)

        // `void push(); ws.data.timer = setInterval(push, PANE_MS)` — first frame
        // immediately, then on the paneMs grid. The deadline is carried forward so
        // a fast read keeps the interval and a slow one only ever delays itself.
        let poll = Task {
            var next = ContinuousClock.now
            while !Task.isCancelled {
                await watcher.push()
                next = next.advanced(by: .milliseconds(paneMs))
                let now = ContinuousClock.now
                if next > now {
                    try? await Task.sleep(until: next, clock: .continuous)
                } else {
                    next = now
                }
            }
        }

        do {
            for try await message in inbound.messages(maxSize: Self.maxInboundMessage) {
                await handle(message, watcher: watcher, paneId: paneId)
            }
        } catch {
            // the socket went away mid-read; closing is the whole response
        }

        poll.cancel()
        await watcher.close()
        await watchers.remove(watcher, pane: paneId)
        log.socket("close", pane: paneId)
    }

    /// `message(ws, raw)`: three verbs, then clear and show. Note that the clear
    /// and the nudge sit AFTER the if/else chain in server.ts, so a message of an
    /// unknown type sends nothing to herdr but still forces a frame.
    private func handle(_ message: WebSocketMessage, watcher: PaneWatcher, paneId: String) async {
        let raw: String
        switch message {
        case .text(let string): raw = string
        // Bun's handler takes `string | Buffer` and does String(raw) either way
        case .binary(let buffer): raw = String(buffer: buffer)
        }

        do {
            let msg = try JSONCoding.decode(PaneClientMessage.self, from: Data(raw.utf8))
            if msg.type == "text", let text = msg.text, !text.isEmpty {
                try await herdr.sendText(paneId, text)
            } else if msg.type == "keys", let keys = msg.keys, !keys.isEmpty {
                try await herdr.sendKeys(paneId, keys)
            } else if msg.type == "prompt", let text = msg.text, !text.isEmpty {
                try await herdr.prompt(paneId, text)
            }
            await watcher.clearLast()
            await nudge(paneId)  // show it now, do not wait for the next tick
        } catch {
            try? await watcher.send(PaneErrorMessage(error: jsErrorString(error)))
        }
    }
}

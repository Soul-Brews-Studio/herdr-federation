// HerdrClient.swift — src/herdr.ts.
//
// Transport, from that file's header, unchanged:
//   - unix socket at socketPath, newline-delimited JSON
//   - request  {"id":"fed-<n>","method":<string>,"params":<object>}, n global, from 1
//   - reply    {"id",..,"result":{..}} | {"id":"","error":{code,message}}
//   - ONE-SHOT: the server closes after a single reply, so every call opens its
//     own connection and reads exactly one line.
//   - a request line is capped at 1 MiB and rejected BEFORE connecting.
//
// The call log is what `GET /api/calls` serves: newest first, 200 deep, one
// entry per transaction, each with the herdr command line you could have typed
// instead. Which transactions get an entry is NOT "all of them" — see `call`.

import Foundation

// MARK: - the module-global request counter (`let seq = 0` in herdr.ts)

/// herdr.ts numbers requests from a module-global, so two clients in one
/// process share the sequence. Kept global here for the same ids on the wire.
private final class SeqCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    /// `++seq` — the first id is `fed-1`.
    func next() -> Int {
        lock.lock()
        defer { lock.unlock() }
        n += 1
        return n
    }
}

private let herdrSeq = SeqCounter()

// MARK: - the call log

/// `CALLS` in herdr.ts: unshift, then truncate to 200.
private actor CallLog {
    private var entries: [CallRecord] = []

    func record(_ entry: CallRecord) {
        entries.insert(entry, at: 0)
        if entries.count > Const.callsCap { entries.removeLast(entries.count - Const.callsCap) }
    }

    func all() -> [CallRecord] { entries }
}

// MARK: - JS string semantics, for toCli only

/// `String(v)` the way JS prints it — `toCli` interpolates raw params.
private func jsString(_ v: JSONValue) -> String {
    switch v {
    case .string(let s): return s
    case .number(let n): return jsNumber(n)
    case .bool(let b): return b ? "true" : "false"
    case .null: return "null"
    // Array.prototype.toString: join(",") with null/undefined rendered empty
    case .array(let a): return a.map { $0 == .null ? "" : jsString($0) }.joined(separator: ",")
    case .object: return "[object Object]"
    }
}

private func jsNumber(_ n: Double) -> String {
    if n.isNaN { return "NaN" }
    if n.isInfinite { return n > 0 ? "Infinity" : "-Infinity" }
    if n == n.rounded(), abs(n) < 1e21 { return String(Int64(n)) }
    return String(n)
}

/// `JSON.stringify(s)` for a string — the quoted form `q()` falls back to.
private func jsonQuote(_ s: String) -> String {
    var out = "\""
    for scalar in s.unicodeScalars {
        switch scalar {
        case "\"": out += "\\\""
        case "\\": out += "\\\\"
        case "\n": out += "\\n"
        case "\r": out += "\\r"
        case "\t": out += "\\t"
        case "\u{08}": out += "\\b"
        case "\u{0C}": out += "\\f"
        default:
            if scalar.value < 0x20 { out += String(format: "\\u%04x", scalar.value) } else { out.unicodeScalars.append(scalar) }
        }
    }
    return out + "\""
}

/// `const q = (v) => { const s = String(v ?? ""); return /^[A-Za-z0-9_:.\/-]+$/.test(s) ? s : JSON.stringify(s) }`
/// — `??` catches null AND absent, so both become the empty string, which fails
/// the `+` and comes back as a quoted `""`.
private func shellArg(_ v: JSONValue?) -> String {
    let s: String
    if let v, v != .null { s = jsString(v) } else { s = "" }
    if s.range(of: "^[A-Za-z0-9_:./-]+$", options: .regularExpression) != nil { return s }
    return jsonQuote(s)
}

/// `String.prototype.replace(regex, string)` with a non-global regex: first match only.
private func replaceFirst(_ s: String, pattern: String, with replacement: String) -> String {
    guard let re = try? NSRegularExpression(pattern: pattern) else { return s }
    let ns = s as NSString
    guard let m = re.firstMatch(in: s, range: NSRange(location: 0, length: ns.length)) else { return s }
    return ns.replacingCharacters(in: m.range, with: replacement)
}

// MARK: - what came back off the wire

private enum WireOutcome: Sendable {
    /// the bytes up to the first "\n"
    case reply(String)
    /// node's `socket.on("error")` — connect, read or write failed
    case failed(String)
    /// node's `socket.on("close")` — EOF before a newline
    case closed
    /// the `setTimeout` fired first
    case timedOut
}

/// One settle, one resume. Every callback races here; the first one wins and
/// tears the connection down.
private final class WireBox: @unchecked Sendable {
    private let lock = NSLock()
    private var settled = false
    private var continuation: CheckedContinuation<WireOutcome, Never>?
    private var pending: WireOutcome?

    init() {}

    /// Hand the box its continuation. A callback that already fired resumes now.
    func arm(_ c: CheckedContinuation<WireOutcome, Never>) {
        lock.lock()
        if let outcome = pending {
            lock.unlock()
            c.resume(returning: outcome)
            return
        }
        continuation = c
        lock.unlock()
    }

    var isSettled: Bool { lock.lock(); defer { lock.unlock() }; return settled }

    func settle(_ outcome: WireOutcome) {
        lock.lock()
        if settled { lock.unlock(); return }
        settled = true
        let c = continuation
        continuation = nil
        if c == nil { pending = outcome }
        lock.unlock()
        c?.resume(returning: outcome)
    }
}

/// `let buf = ""` in the data handler: accumulate, cut at the first newline.
private final class LineBuffer: @unchecked Sendable {
    private var data = Data()
    func append(_ chunk: Data) -> String? {
        data.append(chunk)
        guard let nl = data.firstIndex(of: 0x0A) else { return nil }
        return String(decoding: data[data.startIndex..<nl], as: UTF8.self)
    }
}

// MARK: - the client

public final class SocketHerdrClient: HerdrClient {
    public let socketPath: String
    private let log = CallLog()

    public init(socketPath: String) {
        self.socketPath = socketPath
    }

    // MARK: toCli

    /// The same operation as a herdr command line, so every transaction is
    /// inspectable and reproducible by hand. nil where the CLI has no verb.
    public static func toCli(_ method: String, _ p: [String: JSONValue]) -> String? {
        // `const s = (k) => (p[k] === undefined ? "" : String(p[k]))` — an explicit
        // null is NOT undefined, so it prints as the four characters `null`.
        func s(_ k: String) -> String { p[k].map(jsString) ?? "" }

        switch method {
        case "session.snapshot": return "herdr api snapshot"
        case "agent.list": return "herdr agent list"
        case "pane.list": return "herdr pane list"
        case "workspace.list": return "herdr workspace list"
        case "pane.read":
            // `||` not `??`: an empty string falls through to the default too
            let source = s("source").isEmpty ? "recent" : s("source")
            let format = s("format").isEmpty ? "text" : s("format")
            let line = "herdr pane read \(shellArg(p["pane_id"])) --source \(source) --lines \(s("lines")) --format \(format)"
            // Meant to drop an empty `--lines`. It never fires — see the note in `call`.
            return replaceFirst(line, pattern: #"\s+--lines\s(?=--)"#, with: " ")
        case "pane.send_keys":
            let keys = p["keys"]?.arrayValue ?? []
            return "herdr agent send-keys \(shellArg(p["pane_id"])) \(keys.map { shellArg($0) }.joined(separator: " "))"
        case "pane.send_text":
            // no CLI verb writes raw text without submitting; `agent prompt` is text+Enter
            return nil
        default:
            return nil
        }
    }

    // MARK: one request, one connection, one reply

    private struct RequestEnvelope: Encodable {
        let id: String
        let method: String
        let params: [String: JSONValue]
    }

    public func call(_ method: String, params: [String: JSONValue] = [:], timeoutMs: Int = Const.herdrTimeoutMs) async throws -> JSONValue {
        let now = Date()
        let at = Stamp.iso(now)
        let startedMs = Int64(now.timeIntervalSince1970 * 1000)

        // `++seq` happens while building the line, so even a rejected request burns an id
        var line = try JSONCoding.encode(RequestEnvelope(id: "fed-\(herdrSeq.next())", method: method, params: params))
        line.append(0x0A)
        if line.count >= Const.herdrMaxLineBytes {
            // rejected before connecting, and deliberately NOT recorded
            throw HerdrError(code: "request_too_large", message: "\(method) exceeds the 1 MiB request cap")
        }

        let outcome = await transact(line: line, timeoutMs: timeoutMs)
        let ms = Int(Stamp.nowMs() - startedMs)
        let cli = Self.toCli(method, params)

        func finish(ok: Bool, error: String?) async {
            await log.record(CallRecord(at: at, method: method, params: params, cli: cli, ms: ms, ok: ok, error: error))
        }

        switch outcome {
        case .reply(let raw):
            let msg: JSONValue
            do {
                msg = try JSONCoding.decode(JSONValue.self, from: Data(raw.utf8))
            } catch {
                // herdr.ts rejects here WITHOUT calling finish(): a malformed line
                // leaves no trace in the call log.
                throw HerdrError(code: "bad_response", message: "\(error)")
            }
            if let envelope = msg["error"], isTruthy(envelope) {
                let code = envelope["code"]?.stringValue
                let message = envelope["message"]?.stringValue
                await finish(ok: false, error: message ?? code)
                throw HerdrError(code: code ?? "error", message: message ?? "herdr error")
            }
            await finish(ok: true, error: nil)
            // a reply with no `result` resolves as null in Bun too; the caller's
            // property access is what fails, one frame later
            return msg["result"] ?? .null

        case .failed(let message):
            await finish(ok: false, error: message)
            throw HerdrError(code: "socket", message: message)

        case .closed:
            // the server closing before a reply is itself the failure signal — and,
            // like the timeout, it is not recorded
            throw HerdrError(code: "closed", message: "\(method): connection closed with no reply")

        case .timedOut:
            throw HerdrError(code: "timeout", message: "\(method) timed out")
        }
    }

    /// JS truthiness for `if (msg.error)`.
    private func isTruthy(_ v: JSONValue) -> Bool {
        switch v {
        case .null: return false
        case .bool(let b): return b
        case .number(let n): return n != 0 && !n.isNaN
        case .string(let s): return !s.isEmpty
        case .array, .object: return true
        }
    }

    // MARK: transport

    /// One request, one AF_UNIX connection, one reply line.
    ///
    /// This was Network.framework (`NWConnection(to: .unix(path:), using: .tcp)`)
    /// and that is measurably broken on this machine: NWConnection runs nw_path
    /// evaluation even for a unix-domain endpoint, and while the path is still
    /// unsatisfied it reports `.failed(POSIXErrorCode(50))`. Measured against the
    /// live herdr socket: 11 of the first 12 connections in a process died as
    /// `connect ENETDOWN`, while a plain `socket(AF_UNIX)`/`connect` over the
    /// same path was 16 for 16 across repeated runs. A unix socket has no network
    /// path, so the whole evaluation is noise — the syscalls are the transport.
    ///
    /// Every outcome, error string and timing rule below is unchanged, so `call`
    /// and the call log see exactly what they saw before.
    private func transact(line: Data, timeoutMs: Int) async -> WireOutcome {
        let box = WireBox()
        let path = socketPath
        let deadline = DispatchTime.now() + .milliseconds(timeoutMs)
        let timer = DispatchQueue(label: "fed.herdr.timeout")
        timer.asyncAfter(deadline: deadline) { box.settle(.timedOut) }

        // A blocking socket on its own thread, with poll() bounded by the same
        // deadline — the box still settles once, first writer wins.
        DispatchQueue.global(qos: .userInitiated).async {
            Self.pump(line: line, path: path, deadline: deadline, box: box)
        }

        return await withCheckedContinuation { (continuation: CheckedContinuation<WireOutcome, Never>) in
            box.arm(continuation)
        }
    }

    /// connect · write · read-to-newline, all on one blocking fd. `phase` in every
    /// error matches what node:net names the failing syscall.
    private static func pump(line: Data, path: String, deadline: DispatchTime, box: WireBox) {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        if fd < 0 { box.settle(.failed(message(errno, phase: "socket", path: nil))); return }
        defer { close(fd) }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        let capacity = MemoryLayout.size(ofValue: addr.sun_path)
        guard bytes.count < capacity else {
            box.settle(.failed(connectFailure(path))); return
        }
        withUnsafeMutablePointer(to: &addr.sun_path) { p in
            p.withMemoryRebound(to: CChar.self, capacity: capacity) { dst in
                for (i, b) in bytes.enumerated() { dst[i] = CChar(bitPattern: b) }
                dst[bytes.count] = 0
            }
        }
        addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)

        // connect(2) on a BLOCKING fd has no deadline of its own: if herdr is
        // stopped (SIGSTOP) or its accept backlog is full, the socket stays
        // bound and connect simply blocks. The caller is resumed by the timeout
        // thread, but this libdispatch worker and this fd stay pinned — and with
        // a /ws/pane viewer polling every 300 ms and a sync every 2 s, the global
        // pool runs out and no pump starts at all. node:net is non-blocking and
        // `socket.destroy()` tears the attempt down at the 5 s mark, so nothing
        // accumulates there. Same shape here: O_NONBLOCK, then EINPROGRESS driven
        // through the same deadline-bounded poll() the read phase already uses.
        let originalFlags = fcntl(fd, F_GETFL, 0)
        if originalFlags >= 0 { _ = fcntl(fd, F_SETFL, originalFlags | O_NONBLOCK) }

        let connected = withUnsafePointer(to: &addr) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                Darwin.connect(fd, sa, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        if connected != 0 {
            guard errno == EINPROGRESS || errno == EINTR else {
                box.settle(.failed(connectFailure(path))); return
            }
            // wait for writability, never past the caller's deadline
            var settled = false
            while !box.isSettled {
                var pfd = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
                if deadline < DispatchTime.now() { return }   // the timer settles it
                let remaining = deadline.uptimeNanoseconds &- DispatchTime.now().uptimeNanoseconds
                let ready = poll(&pfd, 1, Int32(min(remaining / 1_000_000, 60_000)))
                if ready < 0 {
                    if errno == EINTR { continue }
                    box.settle(.failed(connectFailure(path))); return
                }
                if ready == 0 { continue }
                var soError: Int32 = 0
                var length = socklen_t(MemoryLayout<Int32>.size)
                if getsockopt(fd, SOL_SOCKET, SO_ERROR, &soError, &length) != 0 || soError != 0 {
                    box.settle(.failed(connectFailure(path))); return
                }
                settled = true
                break
            }
            if !settled { return }   // the box was settled under us
        }
        if originalFlags >= 0 { _ = fcntl(fd, F_SETFL, originalFlags) }

        // The timeout thread may already have settled the box; stop rather than
        // hold the socket open behind a caller that has moved on.
        if box.isSettled { return }

        var written = 0
        line.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let base = raw.baseAddress else { return }
            while written < raw.count {
                let n = Darwin.write(fd, base.advanced(by: written), raw.count - written)
                if n > 0 { written += n; continue }
                if n < 0 && (errno == EINTR || errno == EAGAIN) { continue }
                box.settle(.failed(message(errno, phase: "write", path: nil)))
                return
            }
        }
        if box.isSettled { return }

        let buffer = LineBuffer()
        var chunk = [UInt8](repeating: 0, count: 64 * 1024)
        while !box.isSettled {
            // poll rather than a blocking read, so a dead server cannot pin this
            // thread past the caller's timeout
            var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let remaining = deadline.uptimeNanoseconds &- DispatchTime.now().uptimeNanoseconds
            if deadline < DispatchTime.now() { return }   // the timer settles it
            let ready = poll(&pfd, 1, Int32(min(remaining / 1_000_000, 60_000)))
            if ready < 0 {
                if errno == EINTR { continue }
                box.settle(.failed(message(errno, phase: "read", path: nil)))
                return
            }
            if ready == 0 { continue }

            let n = chunk.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
            if n > 0 {
                if let reply = buffer.append(Data(chunk[0..<n])) { box.settle(.reply(reply)); return }
                continue
            }
            if n == 0 { box.settle(.closed); return }          // node's `close` with no reply
            if errno == EINTR || errno == EAGAIN { continue }
            box.settle(.failed(message(errno, phase: "read", path: nil)))
            return
        }
    }

    /// BUN: every failed unix-socket `connect()` is reported as `connect ENOENT
    /// <path>`, whatever the kernel said. Measured on Bun 1.3.14 against a bound
    /// socket with no listener (kernel ECONNREFUSED), a `chmod 000` socket
    /// (EACCES), a directory and a regular file (ENOTSOCK) and a 120-byte path
    /// (ENAMETOOLONG): node:net under Bun printed ENOENT for all five, while
    /// Node 26 printed the real name. The fleet runs Bun, so this node says what
    /// Bun says; the errno table below still names the other syscalls.
    private static func connectFailure(_ path: String) -> String {
        message(ENOENT, phase: "connect", path: path)
    }

    /// node's `err.message` is `<syscall> <ERRNO>[ <path>]` — `connect ENOENT /x.sock`.
    private static func message(_ code: Int32, phase: String, path: String?) -> String {
        let name = errnoNames[code] ?? "errno \(code)"
        if let path { return "\(phase) \(name) \(path)" }
        return "\(phase) \(name)"
    }

    private static let errnoNames: [Int32: String] = [
        1: "EPERM", 2: "ENOENT", 4: "EINTR", 5: "EIO", 9: "EBADF", 12: "ENOMEM",
        13: "EACCES", 14: "EFAULT", 22: "EINVAL", 23: "ENFILE", 24: "EMFILE",
        32: "EPIPE", 35: "EAGAIN", 36: "EINPROGRESS", 40: "EMSGSIZE",
        49: "EADDRNOTAVAIL", 50: "ENETDOWN", 51: "ENETUNREACH", 53: "ECONNABORTED",
        54: "ECONNRESET", 55: "ENOBUFS", 57: "ENOTCONN", 60: "ETIMEDOUT",
        61: "ECONNREFUSED", 62: "ELOOP", 63: "ENAMETOOLONG", 64: "EHOSTDOWN",
        65: "EHOSTUNREACH",
    ]

    // MARK: decoding a result into a protocol shape

    private static func decode<T: Decodable>(_ type: T.Type, from value: JSONValue?) throws -> T {
        try JSONCoding.decode(type, from: JSONCoding.encode(value ?? .null))
    }

    // MARK: the seven RPCs

    /// The whole herd in one RPC; falls back to the older trio on servers that lack it.
    public func snapshot() async throws -> HerdrSnapshot {
        do {
            let res = try await call("session.snapshot")
            return try Self.decode(HerdrSnapshot.self, from: res["snapshot"])
        } catch is HerdrError {
            // older servers predate session.snapshot; rebuild what we can from the trio
            async let workspaces = call("workspace.list")
            async let panes = call("pane.list")
            let (w, p) = try await (workspaces, panes)
            var snap = HerdrSnapshot()
            snap.workspaces = (try? Self.decode([HerdrWorkspace].self, from: w["workspaces"])) ?? []
            snap.panes = (try? Self.decode([HerdrPane].self, from: p["panes"])) ?? []
            return snap
        }
    }

    public func agents() async throws -> [HerdrPane] {
        let res = try await call("agent.list")
        guard let list = res["agents"], list != .null else { return [] }
        return try Self.decode([HerdrPane].self, from: list)
    }

    /// source ∈ visible | recent | recent_unwrapped | detection — snake_case on the wire.
    ///
    /// Use `visible` for anything on a timer. `recent` asks for scrollback, and on
    /// an idle agent herdr gathers it by driving the pane's own mouse-scroll: the
    /// operator sees their terminal scroll and snap back once per read. `visible`
    /// is the rendered viewport — at the cost of a `revision` that never moves, so
    /// diff on the text.
    /// `lines` is a `JSONValue` so the NaN `/api/pane/?lines=abc` produces can
    /// reach the wire as `"lines":null` (JSON.stringify's rendering of NaN) with
    /// a `--lines NaN` cli line, which is what herdr.ts's nullish `?? 200` lets
    /// through. nil = the key was absent, and only then does the 200 apply.
    public func readPane(_ paneId: String, source: String? = nil, lines: JSONValue? = nil, format: String? = nil) async throws -> HerdrPaneRead {
        let res = try await call("pane.read", params: [
            "pane_id": .string(paneId),
            "source": .string(source ?? Const.herdrDefaultSource),
            "lines": lines ?? .number(Double(Const.herdrDefaultLines)),
            "format": .string(format ?? Const.herdrDefaultFormat),
        ])
        // `"read" in res ? res.read : res` — the server answers either shape
        if let read = res["read"] { return try Self.decode(HerdrPaneRead.self, from: read) }
        return try Self.decode(HerdrPaneRead.self, from: res)
    }

    /// Writes RAW bytes — no bracketed paste, and no Enter.
    public func sendText(_ paneId: String, _ text: String) async throws {
        _ = try await call("pane.send_text", params: ["pane_id": .string(paneId), "text": .string(text)])
    }

    /// Key grammar is herdr's own, NOT tmux: `Enter`, `Escape`, `ctrl+c`,
    /// `shift+tab`, bare single characters. `C-c` and PageUp are invalid_key.
    public func sendKeys(_ paneId: String, _ keys: [String]) async throws {
        _ = try await call("pane.send_keys", params: ["pane_id": .string(paneId), "keys": .array(keys.map { .string($0) })])
    }

    /// Type a line and submit it, the two-step herdr requires.
    public func prompt(_ paneId: String, _ text: String) async throws {
        try await sendText(paneId, text)
        try await sendKeys(paneId, ["Enter"])
    }

    public func isUp() async -> Bool {
        do {
            _ = try await call("pane.list", params: [:], timeoutMs: Const.herdrIsUpTimeoutMs)
            return true
        } catch {
            return false
        }
    }

    public func calls() async -> [CallRecord] { await log.all() }
}

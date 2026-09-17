import Foundation

/// Shared ISO-8601 parsing. The node stamps `new Date().toISOString()`, which
/// always carries milliseconds, and ISO8601DateFormatter without
/// `.withFractionalSeconds` returns nil for exactly that — the bug that printed
/// "seen never" beside a peer marked reachable. Both shapes are accepted.
enum ISO {
    private static let fractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let plain = ISO8601DateFormatter()

    static func date(_ s: String?) -> Date? {
        guard let s else { return nil }
        return fractional.date(from: s) ?? plain.date(from: s)
    }
}

/**
 The only place in the whole system where a RATE exists.

 `stats` on the node are since-boot cumulative counters, and `federation.ts`
 persists only `seq` plus the last 500 messages — so the console renders the same
 monotonic ramp this does. Nothing server-side can answer "how many errors in the
 last five minutes", which is exactly the question that would have killed the
 `errors 1676` scare on sight: that was a since-boot total from an outage an hour
 earlier, beside a peer that was healthy at the time.

 So the tray keeps its own short window in memory. It is deliberately not
 persisted: a rate that survives a restart is a rate measured across a gap.
 */
struct Sample {
    let at: Date
    let pushed: Int
    let pushErrors: Int
    let pullOk: Int
    let pullErrors: Int
}

struct Series {
    /// one point per sample, already differenced — events since the previous sample
    var deltas: [Double] = []
    /// true where the gap to the previous sample was too long to draw across
    var breaks: [Bool] = []
    var perMinute: Double = 0
    var errors: Int = 0
    var stalledFor: TimeInterval?
}

final class Window {
    /// Five minutes is the span the verdict reasons over. Longer hides a fresh
    /// failure behind an hour of health; shorter is noise at a 5s cadence.
    static let span: TimeInterval = 300
    private(set) var samples: [Sample] = []

    func add(_ s: Sample) {
        // A counter that went DOWN means the node restarted, and differencing
        // across that boundary would invent a huge negative or a huge positive.
        // Drop the history instead of lying about it.
        if let last = samples.last, s.pushed < last.pushed || s.pullOk < last.pullOk {
            samples = []
        }
        samples.append(s)
        let cutoff = s.at.addingTimeInterval(-Self.span)
        samples.removeAll { $0.at < cutoff }
    }

    func clear() { samples = [] }

    /// `ok` and `err` pick the counters; both are cumulative on the wire.
    func series(_ ok: KeyPath<Sample, Int>, _ err: KeyPath<Sample, Int>, cadence: TimeInterval) -> Series {
        guard samples.count >= 2 else { return Series() }
        var out = Series()
        var events = 0.0
        var errs = 0
        for i in 1..<samples.count {
            let a = samples[i - 1], b = samples[i]
            let dt = b.at.timeIntervalSince(a.at)
            // A path that keeps drawing while nothing was measured is a lie. Any
            // gap beyond 3x the poll cadence breaks the line rather than
            // interpolating a value nobody observed.
            let broke = dt > cadence * 3
            let d = Double(b[keyPath: ok] - a[keyPath: ok])
            out.deltas.append(max(0, d))
            out.breaks.append(broke)
            events += max(0, d)
            errs += max(0, b[keyPath: err] - a[keyPath: err])
        }
        let span = samples.last!.at.timeIntervalSince(samples.first!.at)
        out.perMinute = span > 0 ? events / span * 60 : 0
        out.errors = errs
        // "stopped Nm ago" — the last sample that actually moved the counter
        if let lastMove = (1..<samples.count).reversed().first(where: { samples[$0][keyPath: ok] > samples[$0 - 1][keyPath: ok] }) {
            let since = Date().timeIntervalSince(samples[lastMove].at)
            out.stalledFor = since > cadence * 3 ? since : nil
        } else {
            out.stalledFor = Date().timeIntervalSince(samples.first!.at)
        }
        return out
    }
}

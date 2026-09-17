import SwiftUI

/// What the popover renders. Published as one value so a poll swaps the whole
/// snapshot at once — a view that reads five independently-updating properties
/// can paint a frame where the verdict disagrees with the rows under it.
final class Watch: ObservableObject {
    @Published var status: NodeStatus?
    @Published var admin: AdminState?
    @Published var offline: String?
    @Published var push = Series()
    @Published var pull = Series()
    @Published var verdict = Verdict(level: .none, detail: "", peer: nil)
    @Published var expanded = false
    var onConsole: () -> Void = {}
    var onAdmin: () -> Void = {}
    var onRefresh: () -> Void = {}
    var url: String = ""
}

private func ago(_ iso: String?) -> String {
    guard let iso, let d = ISO.date(iso) else { return "never" }
    let s = Int(-d.timeIntervalSinceNow)
    if s < 60 { return "\(max(s, 0))s ago" }
    if s < 3600 { return "\(s / 60)m \(s % 60)s ago" }
    return "\(s / 3600)h ago"
}

private func uptime(_ iso: String?) -> String {
    guard let iso, let d = ISO.date(iso) else { return "—" }
    let s = Int(-d.timeIntervalSinceNow)
    if s < 3600 { return "\(s / 60)m" }
    if s < 86400 { return "\(s / 3600)h \((s % 3600) / 60)m" }
    return "\(s / 86400)d \((s % 86400) / 3600)h"
}

/// A stroked line with real gaps. `breaks[i]` means no sample was taken between
/// i-1 and i, so the path lifts rather than inventing the span.
struct Spark: View {
    let series: Series
    let tint: Color

    var body: some View {
        Canvas { ctx, size in
            let d = series.deltas
            guard d.count >= 2 else { return }
            let hi = max(d.max() ?? 1, 1)
            let dx = size.width / CGFloat(d.count - 1)
            let y: (Double) -> CGFloat = { size.height - CGFloat($0 / hi) * (size.height - 2) - 1 }

            var line = Path()
            var pen = false
            for (i, v) in d.enumerated() {
                let p = CGPoint(x: CGFloat(i) * dx, y: y(v))
                if !pen || series.breaks[safe: i] == true {
                    line.move(to: p); pen = true
                } else {
                    line.addLine(to: p)
                }
            }
            ctx.stroke(line, with: .color(tint), lineWidth: 1.2)
        }
        .frame(height: 18)
    }
}

struct Row: View {
    let label: String
    let series: Series
    let tint: Color

    var body: some View {
        HStack(spacing: 8) {
            Text(label).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary).frame(width: 30, alignment: .leading)
            Spark(series: series, tint: tint).frame(maxWidth: .infinity)
            Text(String(format: "%.1f/min", series.perMinute))
                .font(.system(size: 11, design: .monospaced)).monospacedDigit()
                .foregroundStyle(.secondary).frame(width: 60, alignment: .trailing)
            // payload bytes, not what an interface counter shows — headers and
            // TLS are not in it. Nodes older than this field report 0 B/s.
            Text(rate(series.bytesPerSec))
                .font(.system(size: 11, design: .monospaced)).monospacedDigit()
                .foregroundStyle(.tertiary).frame(width: 64, alignment: .trailing)
            Text("\(series.errors) err")
                .font(.system(size: 11, design: .monospaced)).monospacedDigit()
                .foregroundStyle(series.errors > 0 ? Color.red : .secondary)
                .frame(width: 48, alignment: .trailing)
        }
    }
}

struct Watchfloor: View {
    @ObservedObject var w: Watch

    private var tint: Color {
        switch w.verdict.level {
        case .healthy: return .green
        case .degraded: return .orange
        case .down: return .red
        case .none: return .secondary
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            identity
            Divider()
            chip
            Divider()
            link
            Divider()
            peers
            Divider()
            fleet
            Divider()
            footer
        }
        .frame(width: 360)
    }

    private var identity: some View {
        HStack(spacing: 6) {
            Text(w.status?.node ?? "—").font(.system(size: 13, weight: .semibold))
            Text(w.status?.identity?.fingerprint ?? "no key")
                .font(.system(size: 11, design: .monospaced)).foregroundStyle(.tertiary)
            Spacer()
            Text(w.url).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
            Text(uptime(w.status?.stats?.startedAt))
                .font(.system(size: 11, design: .monospaced)).monospacedDigit()
                .foregroundStyle(.tertiary).frame(width: 52, alignment: .trailing)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
    }

    private var chip: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button { w.expanded.toggle() } label: {
                HStack(spacing: 8) {
                    Text(w.verdict.level.glyph).foregroundStyle(tint)
                    Text(w.verdict.level.word).font(.system(size: 15, weight: .semibold)).foregroundStyle(tint)
                    Spacer()
                    Text(summary).font(.system(size: 11, design: .monospaced)).monospacedDigit().foregroundStyle(.secondary)
                    Text(w.expanded ? "⌃" : "⌄").foregroundStyle(.tertiary)
                }
            }
            .buttonStyle(.plain)

            // Never red without evidence: an alarm you cannot interrogate is noise.
            if w.expanded || w.verdict.level >= .down {
                VStack(alignment: .leading, spacing: 2) {
                    if !w.verdict.detail.isEmpty {
                        Text(w.verdict.detail).font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    if let p = w.verdict.peer {
                        Text(p.url).font(.system(size: 11, design: .monospaced)).foregroundStyle(.tertiary)
                        Text("\(p.consecutive ?? 0) in a row · last ok \(ago(p.lastOkAt))")
                            .font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                        if let e = p.lastError {
                            Text(e).font(.system(size: 11, design: .monospaced)).foregroundStyle(.red).lineLimit(2)
                        }
                    }
                    if let s = w.pull.stalledFor, w.verdict.level >= .degraded {
                        Text("pull stopped \(Int(s / 60))m \(Int(s) % 60)s ago")
                            .font(.system(size: 11, design: .monospaced)).foregroundStyle(.orange)
                    }
                }
                .padding(.leading, 20)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
    }

    private var summary: String {
        let links = (w.status?.peers ?? []).count
        let errs = w.push.errors + w.pull.errors
        let panes = (w.status?.members ?? []).count
        return "\(links) link\(links == 1 ? "" : "s") · \(errs) err/5m · \(panes) panes"
    }

    private var link: some View {
        VStack(alignment: .leading, spacing: 4) {
            header("LINK — this node", right: "last 5 min")
            Row(label: "push", series: w.push, tint: tint)
            Row(label: "pull", series: w.pull, tint: tint)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
    }

    private var peers: some View {
        VStack(alignment: .leading, spacing: 3) {
            let all = w.status?.peers ?? []
            let direct = all.filter { $0.via == nil }
            let relayed = all.filter { $0.via != nil }
            header("PEERS — links this node keeps", right: "\(direct.count)")
            if direct.isEmpty {
                Text("none — create an invite").font(.system(size: 11)).foregroundStyle(.tertiary)
            }
            ForEach(direct, id: \.name) { p in
                let fails = p.consecutive ?? 0
                HStack(spacing: 6) {
                    Text(fails == 0 ? "●" : "○").foregroundStyle(fails == 0 ? Color.green : .red)
                    Text(p.name).font(.system(size: 12))
                    Spacer()
                    Text(fails == 0 ? "ok \(ago(p.lastSeen))" : "\(fails) fails")
                        .font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                }
                // what this hub lets us see — not our link, so it never moves the verdict
                ForEach(relayed.filter { $0.via == p.name }, id: \.name) { r in
                    let rf = r.consecutive ?? 0
                    HStack(spacing: 6) {
                        Text("◌").foregroundStyle(.tertiary)
                        Text(rf == 0 ? "●" : "○").foregroundStyle(rf == 0 ? Color.green.opacity(0.7) : .red.opacity(0.7))
                        Text(r.name).font(.system(size: 12)).foregroundStyle(.secondary)
                        Text("via \(p.name)").font(.system(size: 10)).foregroundStyle(.tertiary)
                        Spacer()
                        Text(rf == 0 ? "hub ok \(ago(r.lastOkAt))" : "hub: \(rf) fails")
                            .font(.system(size: 11, design: .monospaced)).foregroundStyle(.tertiary)
                    }
                    .padding(.leading, 14)
                }
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
    }

    private var fleet: some View {
        let panes = w.status?.members ?? []
        let agents = panes.filter { (p: Pane) in p.kind != nil && p.kind != "shell" }
        let by = Dictionary(grouping: agents, by: { (p: Pane) in p.status ?? "unknown" })
        let working = by["working"]?.count ?? 0
        let blocked = by["blocked"]?.count ?? 0
        let idle = by["idle"]?.count ?? 0
        let shells = panes.count - agents.count
        return VStack(alignment: .leading, spacing: 4) {
            header("FLEET — \(panes.count) panes on \(w.status?.node ?? "this node")", right: "")
            GeometryReader { g in
                HStack(spacing: 1) {
                    bar(working, panes.count, .green, g.size.width)
                    bar(blocked, panes.count, .red, g.size.width)
                    bar(idle, panes.count, Color.secondary.opacity(0.35), g.size.width)
                    bar(shells, panes.count, Color.secondary.opacity(0.15), g.size.width)
                }
            }
            .frame(height: 6)
            Text("\(working) working · \(idle) idle · \(shells) no agent · \(blocked) blocked")
                .font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
    }

    private func bar(_ n: Int, _ total: Int, _ c: Color, _ w: CGFloat) -> some View {
        Rectangle().fill(c).frame(width: total > 0 ? w * CGFloat(n) / CGFloat(total) : 0)
    }

    private func header(_ l: String, right: String) -> some View {
        HStack {
            Text(l).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
            Spacer()
            Text(right).font(.system(size: 11)).foregroundStyle(.tertiary)
        }
    }

    private var footer: some View {
        HStack(spacing: 14) {
            Button("Open console") { w.onConsole() }.buttonStyle(.plain).keyboardShortcut("o")
            Button("Admin") { w.onAdmin() }.buttonStyle(.plain).keyboardShortcut("a")
            Button("Refresh") { w.onRefresh() }.buttonStyle(.plain).keyboardShortcut("r")
            Spacer()
            Text("⌥click: menu").foregroundStyle(.tertiary)
        }
        .font(.system(size: 11))
        .padding(.horizontal, 12).padding(.vertical, 8)
    }
}

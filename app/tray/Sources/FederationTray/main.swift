// FederationTray — a macOS menu-bar status + controller for herdr-federation.
//
// Shows what this node federates with, creates and revokes invite links, joins
// another node by pasting one, and kicks or bans a member. Mirrors the shape of
// the Structor tray in jsonl-oracle: a stat header, service rows, open actions,
// submenus for the lists, then config/refresh/quit.
//
// Two rules the menu is built around, both inherited from the service:
//
//  1. Enforcement is LOCAL ONLY. A kick removes a member from THIS node; peers
//     see it published and adopt it by their own choice. So the menu keeps
//     "who federates with this node" (actionable) and "what the mesh reports"
//     (read-only) in two different places and never merges them.
//  2. Destructive actions confirm. Kick, ban and revoke each raise an alert
//     naming what would change — the same discipline the justfile's CONFIRM=yes
//     gate enforces on the command line.
//
// Config: ~/.config/herdr-federation/tray.json (see Config.swift)

import AppKit
import Foundation
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    var config = Config.load()
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

    var status: NodeStatus?
    var admin: AdminState?
    var lastError: String?
    var busy: String?
    var timer: Timer?
    let join = JoinPanelController()

    // Watchfloor: the popover. The NSMenu stays, reachable with ⌥click, because
    // a popover cannot hold twenty rows of submenu and the menu cannot hold a
    // sparkline — neither replaces the other.
    let watch = Watch()
    let window = Window()
    lazy var popover: NSPopover = {
        let p = NSPopover()
        p.contentViewController = NSHostingController(rootView: Watchfloor(w: watch))
        // .semitransient, not .transient: measured, a .transient popover from a
        // cold accessory app silently does nothing at all — it never becomes key,
        // so the first click after switching apps appears to do nothing.
        p.behavior = .semitransient
        return p
    }()

    func applicationDidFinishLaunching(_ n: Notification) {
        NSApp.setActivationPolicy(.accessory)
        NSApp.mainMenu = editOnlyMainMenu()   // ⌘V in the join field routes through here
        item.button?.title = "⚯ fed"
        // NOT item.menu: setting it makes every click open the menu and the
        // button action never fires. The menu is shown explicitly on ⌥click.
        item.button?.target = self
        item.button?.action = #selector(clicked)
        item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        watch.onConsole = { [weak self] in self?.openConsole() }
        watch.onAdmin = { [weak self] in self?.openAdmin() }
        watch.onRefresh = { [weak self] in self?.refreshNow() }
        rebuildMenu()
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: Self.cadence, repeats: true) { [weak self] _ in self?.refresh() }
    }

    /// An accessory app gets no main menu, and without one AppKit has nowhere to
    /// dispatch the standard editing key equivalents — so ⌘V would not paste an
    /// invite link into the join panel, which is the one thing that panel is for.
    func editOnlyMainMenu() -> NSMenu {
        let main = NSMenu()
        let editItem = NSMenuItem(title: "Edit", action: nil, keyEquivalent: "")
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        main.addItem(editItem)
        return main
    }

    /// Poll cadence. The gap mark in the sparkline is derived from it, so the two
    /// must come from one place or a normal tick can be drawn as an outage.
    static let cadence: TimeInterval = 5

    @objc func clicked() {
        // ⌥ or right-click reaches the full menu; a plain click is the panel.
        let e = NSApp.currentEvent
        if e?.modifierFlags.contains(.option) == true || e?.type == .rightMouseUp {
            rebuildMenu()
            item.menu = menu
            item.button?.performClick(nil)
            item.menu = nil          // or the NEXT plain click would open the menu too
            return
        }
        if popover.isShown { popover.performClose(nil); return }
        guard let b = item.button else { return }
        refresh()
        popover.show(relativeTo: b.bounds, of: b, preferredEdge: .minY)
        NSApp.activate(ignoringOtherApps: true)
    }

    // ── polling ──────────────────────────────────────────────────────

    func refresh() {
        let base = config.node.url
        Api.fetch(NodeStatus.self, base, "/api/status") { [weak self] r in
            guard let self else { return }
            switch r {
            case .success(let s):
                self.status = s
                self.lastError = nil
                if let st = s.stats {
                    self.window.add(Sample(at: Date(),
                                           pushed: st.pushed ?? 0, pushErrors: st.pushErrors ?? 0,
                                           pullOk: st.pullOk ?? 0, pullErrors: st.pullErrors ?? 0))
                }
            case .failure(let e):
                self.status = nil
                self.lastError = e.message
                // Do not keep sampling a node that is not answering: the series
                // would flatline at zero and read as "quiet", not "down".
                self.window.clear()
            }
            self.publish()
            self.rebuildMenu()
        }
        Api.fetch(AdminState.self, base, "/api/admin") { [weak self] r in
            guard let self else { return }
            if case .success(let a) = r { self.admin = a } else { self.admin = nil }
            self.publish()
            self.rebuildMenu()
        }
    }

    /// One snapshot at a time. Publishing field by field lets the view paint a
    /// frame where the verdict disagrees with the rows beneath it.
    func publish() {
        let push = window.series(\.pushed, \.pushErrors, cadence: Self.cadence)
        let pull = window.series(\.pullOk, \.pullErrors, cadence: Self.cadence)
        watch.status = status
        watch.admin = admin
        watch.offline = lastError
        watch.push = push
        watch.pull = pull
        watch.url = config.node.url
        watch.verdict = Verdict.of(status: status, admin: admin, push: push, pull: pull, offline: lastError)
    }

    // ── formatting ───────────────────────────────────────────────────

    func clock(_ iso: String?) -> String {
        guard let iso, iso.count >= 16 else { return "never" }
        return String(iso.dropFirst(11).prefix(5))
    }

    /// The server stamps `new Date().toISOString()`, which always carries
    /// milliseconds — and ISO8601DateFormatter without `.withFractionalSeconds`
    /// returns nil for exactly that. The menu then read "seen never" beside a
    /// peer marked reachable, which is worse than showing nothing: it says the
    /// link is dead while the dot says it is alive.
    static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    static let isoPlain = ISO8601DateFormatter()

    func ago(_ iso: String?) -> String {
        guard let iso, let d = Self.iso.date(from: iso) ?? Self.isoPlain.date(from: iso) else { return "never" }
        let s = Int(-d.timeIntervalSinceNow)
        if s < 60 { return "\(s)s ago" }
        if s < 3600 { return "\(s / 60)m ago" }
        if s < 86400 { return "\(s / 3600)h ago" }
        return "\(s / 86400)d ago"
    }

    func info(_ menu: NSMenu, _ title: String) {
        let mi = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        mi.isEnabled = false
        menu.addItem(mi)
    }

    func action(_ menu: NSMenu, _ title: String, _ sel: Selector, _ key: String = "", represented: Any? = nil) {
        let mi = NSMenuItem(title: title, action: sel, keyEquivalent: key)
        mi.target = self
        mi.representedObject = represented
        menu.addItem(mi)
    }

    /// Destructive actions name what changes before they change it.
    func confirm(_ message: String, _ detail: String, _ verb: String) -> Bool {
        let a = NSAlert()
        a.messageText = message
        a.informativeText = detail
        a.alertStyle = .warning
        a.addButton(withTitle: verb)
        a.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        return a.runModal() == .alertFirstButtonReturn
    }

    func after(_ err: String?) {
        busy = nil
        if let err {
            let a = NSAlert()
            a.messageText = "The node refused"
            a.informativeText = err
            a.alertStyle = .warning
            NSApp.activate(ignoringOtherApps: true)
            a.runModal()
        }
        refresh()
    }

    // ── the menu ─────────────────────────────────────────────────────

    var menu = NSMenu()

    func rebuildMenu() {
        let m = NSMenu()
        let node = config.node
        let up = status != nil

        let members = admin?.members ?? []
        let invites = admin?.invites ?? []
        let bans = admin?.bans ?? []
        let live = invites.filter { $0.status == "active" }

        // The title is the ambient half of this app. It must say the verdict, not
        // a count that is the same whether the mesh is healthy or on fire.
        switch watch.verdict.level {
        case .healthy: item.button?.title = "⚯ \(members.count)"
        case .degraded: item.button?.title = "⚯ ▲"
        case .down: item.button?.title = "⚯ ✕"
        case .none: item.button?.title = "⚯ ○"
        }
        _ = up

        info(m, "Node: \(status?.node ?? node.name) — \(node.url)")
        if let s = status {
            let key = s.identity?.fingerprint ?? "no key"
            info(m, "key \(key) · \(members.count) member\(members.count == 1 ? "" : "s") · \(live.count) live invite\(live.count == 1 ? "" : "s") · \(bans.count) ban\(bans.count == 1 ? "" : "s")")
            // Deliberately NOT the lifetime totals. `errors` never decays, so an
            // outage an hour ago reads as trouble now — measured: 1676 sat beside
            // a peer marked reachable. Health is per-peer and current; the totals
            // are history and belong where they cannot be mistaken for status.
            let panes = s.members?.count ?? 0
            let sick = (s.peers ?? []).filter { ($0.consecutive ?? 0) > 0 }
            let health = sick.isEmpty
                ? "all links ok"
                : "\(sick.count) link\(sick.count == 1 ? "" : "s") failing"
            info(m, "\(panes) pane\(panes == 1 ? "" : "s") · \(health)")
            for p in (s.peers ?? []) {
                let fails = p.consecutive ?? 0
                let dot = fails == 0 ? "●" : "○"
                let why = fails == 0
                    ? "seen \(ago(p.lastSeen))"
                    : "\(fails) failed since \(ago(p.lastOkAt)) · \(String((p.lastError ?? "unreachable").prefix(36)))"
                info(m, "  \(dot) \(p.name) — \(p.url) · \(why)")
            }
            if s.peers?.isEmpty ?? true { info(m, "  no peers") }
            // The service ships with the legacy escape hatch ON, and while it is on
            // a peer with no token is still accepted — so a kick does not fully
            // close the door. That is worth a row, not a footnote.
            if s.legacyAllowed == true { info(m, "⚠︎ FED_ALLOW_LEGACY is on — untokened peers are still accepted") }
        } else {
            info(m, "offline: \(lastError ?? "…")")
        }
        m.addItem(.separator())

        if up {
            action(m, "Join with an invite link…", #selector(openJoin), "j")
            action(m, "Create invite (24h, unlimited)", #selector(createInvite), "i")
            if let url = status?.invite?.url {
                action(m, "Copy this node's address", #selector(copyAddress), "y", represented: url)
            } else {
                info(m, status?.invite?.hint ?? "not reachable from other machines")
            }
        } else {
            action(m, "Start local node", #selector(startNode), "s")
        }
        m.addItem(.separator())

        action(m, "Open console", #selector(openConsole), "o")
        action(m, "Open admin", #selector(openAdmin), "a")
        m.addItem(.separator())

        // Actionable: who federates with THIS node.
        let mem = NSMenu()
        if members.isEmpty {
            info(mem, "nobody yet — create an invite and send the link")
        }
        for r in members {
            let sub = NSMenu()
            info(sub, r.legacy == true ? "unverified · pre-token peer" : "key \(r.fingerprint ?? "—")")
            info(sub, r.url ?? "address unknown")
            info(sub, "joined \(ago(r.joinedAt))\(r.viaInvite.map { " via invite \($0)" } ?? "") · seen \(ago(r.lastSeen))")
            sub.addItem(.separator())
            action(sub, "Kick \(r.node)…", #selector(kickMember(_:)), represented: r.node)
            action(sub, "Ban \(r.node)…", #selector(banMember(_:)), represented: r.node)
            let mi = NSMenuItem(title: "\(r.legacy == true ? "⚠︎" : "●") \(r.node)", action: nil, keyEquivalent: "")
            mi.submenu = sub
            mem.addItem(mi)
        }
        let memItem = NSMenuItem(title: "Members (\(members.count))", action: nil, keyEquivalent: "")
        memItem.submenu = mem
        m.addItem(memItem)

        // Read-only: what the rest of the mesh reports. Never merged with the above.
        let mesh = NSMenu()
        let reported = admin?.meshMembers ?? [:]
        if reported.isEmpty { info(mesh, "no peer has reported its membership yet") }
        for (peer, list) in reported.sorted(by: { $0.key < $1.key }) {
            info(mesh, "\(peer) federates with \(list.map { $0.node }.joined(separator: ", "))")
        }
        mesh.addItem(.separator())
        info(mesh, "read-only — a kick binds only the node that issued it")
        let meshItem = NSMenuItem(title: "Elsewhere in the mesh", action: nil, keyEquivalent: "")
        meshItem.submenu = mesh
        m.addItem(meshItem)

        let inv = NSMenu()
        if invites.isEmpty { info(inv, "no invites yet") }
        for i in invites.prefix(12) {
            let sub = NSMenu()
            info(sub, i.url ?? "this node has no address to put in a link")
            let cap = i.maxUses.map(String.init) ?? "∞"
            info(sub, "\(i.status) · used \(i.uses)/\(cap)\(i.expiresAt.map { " · expires \(clock($0))" } ?? "")")
            if let by = i.usedBy, !by.isEmpty { info(sub, "used by \(by.map { $0.node }.joined(separator: ", "))") }
            if let note = i.note, !note.isEmpty { info(sub, "“\(note)”") }
            sub.addItem(.separator())
            if let url = i.url { action(sub, "Copy link", #selector(copyAddress), represented: url) }
            if i.status == "active" { action(sub, "Revoke…", #selector(revokeInvite(_:)), represented: i.id) }
            let dot = i.status == "active" ? "●" : "○"
            let mi = NSMenuItem(title: "\(dot) \(i.id) · \(i.status) · \(i.uses)/\(cap)", action: nil, keyEquivalent: "")
            mi.submenu = sub
            inv.addItem(mi)
        }
        let invItem = NSMenuItem(title: "Invites (\(live.count) live)", action: nil, keyEquivalent: "")
        invItem.submenu = inv
        m.addItem(invItem)

        if !bans.isEmpty {
            let bn = NSMenu()
            for b in bans {
                let sub = NSMenu()
                info(sub, b.pubkey.map { "key \(String($0.prefix(16))) pinned" } ?? "node name pinned (no key on record)")
                if let r = b.reason, !r.isEmpty { info(sub, r) }
                sub.addItem(.separator())
                action(sub, "Unban \(b.node)…", #selector(unbanMember(_:)), represented: b.node)
                let mi = NSMenuItem(title: b.node, action: nil, keyEquivalent: "")
                mi.submenu = sub
                bn.addItem(mi)
            }
            let bItem = NSMenuItem(title: "Bans (\(bans.count))", action: nil, keyEquivalent: "")
            bItem.submenu = bn
            m.addItem(bItem)
        }

        let aud = NSMenu()
        let entries = admin?.audit ?? []
        if entries.isEmpty { info(aud, "nothing recorded yet") }
        for e in entries.prefix(15) {
            // The summary is the one fact that tells two entries apart — two joins
            // from the same node land in the same second often enough that a clock
            // alone cannot separate them.
            let tail = e.summary ?? e.reason ?? ""
            info(aud, "\(e.failed ? "✕" : "✓") \(clock(e.at)) \(e.action) \(e.node)\(tail.isEmpty ? "" : " · \(tail)")")
        }
        let aItem = NSMenuItem(title: "Recent audit", action: nil, keyEquivalent: "")
        aItem.submenu = aud
        m.addItem(aItem)

        if let st = status?.stats {
            let sm = NSMenu()
            info(sm, "since \(ago(st.startedAt))")
            info(sm, "push  \(st.pushed ?? 0) ok · \(st.pushErrors ?? 0) failed")
            info(sm, "pull  \(st.pullOk ?? 0) ok · \(st.pullErrors ?? 0) failed")
            info(sm, "\(st.pulled ?? 0) message\((st.pulled ?? 0) == 1 ? "" : "s") ingested from peers")
            sm.addItem(.separator())
            info(sm, "totals never decay — for health read the peer rows above")
            let sItem = NSMenuItem(title: "Sync totals", action: nil, keyEquivalent: "")
            sItem.submenu = sm
            m.addItem(sItem)
        }
        m.addItem(.separator())

        let nodes = NSMenu()
        for n in config.nodes {
            let mi = NSMenuItem(title: "\(n.name) — \(n.url)", action: #selector(pickNode(_:)), keyEquivalent: "")
            mi.target = self
            mi.representedObject = n.name
            mi.state = n.name == config.current ? .on : .off
            nodes.addItem(mi)
        }
        let nItem = NSMenuItem(title: "Node", action: nil, keyEquivalent: "")
        nItem.submenu = nodes
        m.addItem(nItem)

        action(m, "Edit config…", #selector(editConfig), ",")
        action(m, "Refresh", #selector(refreshNow), "r")
        m.addItem(.separator())
        action(m, "Quit Federation Tray", #selector(quit), "q")

        menu = m
    }

    // ── actions ──────────────────────────────────────────────────────

    @objc func refreshNow() { config = Config.load(); refresh() }

    @objc func pickNode(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String else { return }
        config.current = name
        config.save()
        status = nil; admin = nil; lastError = nil
        rebuildMenu()
        refresh()
    }

    @objc func openConsole() { NSWorkspace.shared.open(URL(string: config.node.url)!) }
    @objc func openAdmin() { NSWorkspace.shared.open(URL(string: config.node.url + "/admin")!) }

    @objc func copyAddress(_ sender: NSMenuItem) {
        guard let s = sender.representedObject as? String else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
    }

    @objc func openJoin() {
        join.show(nodeName: status?.node ?? config.node.name, base: config.node.url) { [weak self] in self?.refresh() }
    }

    @objc func createInvite() {
        Api.fetch(CreateInviteReply.self, config.node.url, "/api/invites", method: "POST",
                  body: ["hours": 24]) { [weak self] r in
            guard let self else { return }
            switch r {
            case .success(let reply):
                if let url = reply.invite.url {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(url, forType: .string)
                }
                self.refresh()
            case .failure(let e):
                self.after(e.message)
            }
        }
    }

    struct CreateInviteReply: Decodable { var invite: InviteLink }

    @objc func revokeInvite(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        guard confirm("Revoke invite \(id)?",
                      "Future joins through this link are refused. Anyone who already joined through it keeps their membership — use Kick for that.",
                      "Revoke") else { return }
        Api.call(config.node.url, "/api/invites/\(id)", method: "DELETE") { [weak self] err in self?.after(err) }
    }

    @objc func kickMember(_ sender: NSMenuItem) {
        guard let node = sender.representedObject as? String else { return }
        guard confirm("Kick \(node)?",
                      "Their token stops authenticating immediately and this node stops syncing with them. They can return through any invite that is still valid — use Ban if that is not what you want.\n\nThis binds only \(status?.node ?? config.node.name). Peers see the kick published and adopt it by their own choice.",
                      "Kick") else { return }
        Api.call(config.node.url, "/api/members/\(node)/kick", method: "POST",
                 body: ["reason": "via tray"]) { [weak self] err in self?.after(err) }
    }

    @objc func banMember(_ sender: NSMenuItem) {
        guard let node = sender.representedObject as? String else { return }
        guard confirm("Ban \(node)?",
                      "A ban is a kick whose effect outlives every future invite: their public key is pinned, so redeeming any invite is refused until you unban them.",
                      "Ban") else { return }
        Api.call(config.node.url, "/api/members/\(node)/ban", method: "POST",
                 body: ["reason": "via tray"]) { [weak self] err in self?.after(err) }
    }

    @objc func unbanMember(_ sender: NSMenuItem) {
        guard let node = sender.representedObject as? String else { return }
        guard confirm("Unban \(node)?",
                      "They will be able to redeem invites again. Unban is not itself an invite — they still need a valid link.",
                      "Unban") else { return }
        Api.call(config.node.url, "/api/members/\(node)/unban", method: "POST", body: [:]) { [weak self] err in self?.after(err) }
    }

    /// Only ever starts the node this tray can see on loopback. A remote node is
    /// somebody else's process; the menu shows it and never reaches for it.
    @objc func startNode() {
        guard let repo = config.repo else {
            after("no repo on disk — set \"repoDir\" in \(Config.path.path)")
            return
        }
        guard config.node.url.contains("127.0.0.1") || config.node.url.contains("localhost") else {
            after("\(config.node.name) is remote — start it on that machine")
            return
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = ["just", "node", "start"]
        p.currentDirectoryURL = repo
        do { try p.run() } catch { after("could not run just: \(error.localizedDescription)") }
    }

    @objc func editConfig() {
        if !FileManager.default.fileExists(atPath: Config.path.path) { config.save() }
        NSWorkspace.shared.open(Config.path)
    }

    @objc func quit() { NSApp.terminate(nil) }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()

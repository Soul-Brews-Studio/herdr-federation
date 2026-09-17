// A floating panel for the one action that needs typing: pasting an invite link.
//
// Everything else in this tray is a menu item, because a menu item cannot be
// half-filled-in. Joining is different — the secret arrives as a URL from
// somewhere else, and pasting it into a menu is not a thing you can do.

import AppKit

final class JoinPanel: NSPanel {
    override func cancelOperation(_ sender: Any?) { close() }
    override var canBecomeKey: Bool { true }
}

final class JoinPanelController: NSObject {
    private var panel: JoinPanel?
    private let field = NSTextField()
    private let status = NSTextField(labelWithString: "")
    private let button = NSButton(title: "Join", target: nil, action: nil)
    private var base = ""
    private var onJoined: (() -> Void)?

    func show(nodeName: String, base: String, onJoined: @escaping () -> Void) {
        self.base = base
        self.onJoined = onJoined

        if panel == nil {
            let p = JoinPanel(contentRect: NSRect(x: 0, y: 0, width: 520, height: 150),
                              styleMask: [.titled, .closable, .utilityWindow],
                              backing: .buffered, defer: false)
            p.title = "Join a federation"
            p.isFloatingPanel = true
            p.hidesOnDeactivate = false

            let label = NSTextField(labelWithString: "Paste an invite link. The secret in it is spent once; your membership is what persists.")
            label.font = .systemFont(ofSize: 11)
            label.textColor = .secondaryLabelColor
            label.lineBreakMode = .byWordWrapping
            label.maximumNumberOfLines = 2

            field.placeholderString = "http://host:6750/join/<secret>"
            field.font = .monospacedSystemFont(ofSize: 12, weight: .regular)

            status.font = .systemFont(ofSize: 11)
            status.textColor = .secondaryLabelColor

            button.target = self
            button.action = #selector(submit)
            button.keyEquivalent = "\r"

            let stack = NSStackView(views: [label, field, status, button])
            stack.orientation = .vertical
            stack.alignment = .leading
            stack.spacing = 8
            stack.edgeInsets = NSEdgeInsets(top: 14, left: 16, bottom: 14, right: 16)
            stack.translatesAutoresizingMaskIntoConstraints = false
            p.contentView?.addSubview(stack)
            NSLayoutConstraint.activate([
                stack.leadingAnchor.constraint(equalTo: p.contentView!.leadingAnchor),
                stack.trailingAnchor.constraint(equalTo: p.contentView!.trailingAnchor),
                stack.topAnchor.constraint(equalTo: p.contentView!.topAnchor),
                field.widthAnchor.constraint(equalToConstant: 480),
                label.widthAnchor.constraint(equalToConstant: 480),
            ])
            panel = p
        }

        panel?.title = "Join a federation — as \(nodeName)"
        status.stringValue = ""
        button.isEnabled = true
        panel?.center()
        panel?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        panel?.makeFirstResponder(field)
    }

    /// `http://host:6750/join/<secret>` -> the two things the node needs. Parsed
    /// here rather than server-side because the console does the same split, and
    /// a link that is not an invite should be rejected before a request is made.
    static func parse(_ raw: String) -> (from: String, token: String)? {
        guard let u = URL(string: raw.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = u.scheme, let host = u.host
        else { return nil }
        let parts = u.path.split(separator: "/").map(String.init)
        guard parts.count >= 2, parts[0] == "join" else { return nil }
        let port = u.port.map { ":\($0)" } ?? ""
        return ("\(scheme)://\(host)\(port)", parts[1].removingPercentEncoding ?? parts[1])
    }

    @objc private func submit() {
        guard let parsed = Self.parse(field.stringValue) else {
            status.stringValue = "that is not an invite link — expected http://host:6750/join/<secret>"
            status.textColor = .systemRed
            return
        }
        status.stringValue = "redeeming at \(parsed.from)…"
        status.textColor = .secondaryLabelColor
        button.isEnabled = false
        Api.call(base, "/api/peers/redeem", method: "POST",
                 body: ["from": parsed.from, "token": parsed.token]) { [weak self] err in
            guard let self else { return }
            self.button.isEnabled = true
            if let err {
                self.status.stringValue = err
                self.status.textColor = .systemRed
                return
            }
            self.status.stringValue = "joined"
            self.status.textColor = .systemGreen
            self.field.stringValue = ""
            self.onJoined?()
        }
    }
}

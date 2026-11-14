import AppKit
import KillSwitchClient
import KillSwitchCore

/// Owns the NSStatusItem and rebuilds its menu from MenuPlan whenever the state changes.
final class StatusController: NSObject {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private(set) var state: UIState
    var config: ConfigView
    var lastResponse: IPCResponse?
    var footer: String?

    /// Set by the app: runs actions that change protection. Nil in demo mode, where they do nothing.
    var perform: ((MenuAction) -> Void)?
    private var built = false

    init(initial: UIState, config: ConfigView) {
        self.state = initial
        self.config = config
        super.init()
        item.button?.imagePosition = .imageLeft
        update(initial)
    }

    func update(_ s: UIState) {
        if built && s == state { return }                     // an unchanged menu is not rebuilt (it may be open)
        built = true
        state = s
        guard let b = item.button else { return }
        b.image = StatusIcons.image(for: s.kind)
        b.title = s.title.map { " " + $0 } ?? ""
        b.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        b.toolTip = s.accessibilityLabel
        b.setAccessibilityLabel(s.accessibilityLabel)
        item.menu = buildMenu()
    }

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        for e in MenuPlan.make(state: state, config: config) {
            switch e.action {
            case .separator:
                menu.addItem(.separator())
            case .header:
                let mi = NSMenuItem(); mi.view = HeaderView(state: state); menu.addItem(mi)
            case .trialBanner:
                let mi = NSMenuItem(title: e.title, action: nil, keyEquivalent: ""); mi.isEnabled = false; menu.addItem(mi)
            default:
                let mi = NSMenuItem(title: e.title, action: #selector(clicked(_:)), keyEquivalent: "")
                mi.target = self
                mi.representedObject = e.action.rawValue
                mi.isEnabled = e.enabled
                menu.addItem(mi)
            }
        }
        if let f = footer {
            menu.addItem(.separator())
            let mi = NSMenuItem(title: f, action: nil, keyEquivalent: ""); mi.isEnabled = false; menu.addItem(mi)
        }
        return menu
    }

    @objc private func clicked(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let action = MenuAction(rawValue: raw) else { return }
        switch action {
        case .quit: quit()
        case .recovery: RecoveryWindow.show()
        case .details: showDetails()
        case .connectVPN: openNetworkSettings()
        default: perform?(action)
        }
    }

    /// Quitting never changes enforcement, but an unconfirmed trial still reverts, so say so.
    private func quit() {
        if let left = state.trialSecondsLeft {
            let a = NSAlert()
            a.messageText = "Quit while a trial is running?"
            a.informativeText = "The trial still reverts in \(Countdown.format(left)) and protection goes off, unless you run `ksctl confirm`."
            a.addButton(withTitle: "Cancel")
            a.addButton(withTitle: "Quit")
            NSApp.activate(ignoringOtherApps: true)
            if a.runModal() != .alertSecondButtonReturn { return }
        }
        NSApp.terminate(nil)
    }

    private func openNetworkSettings() {
        let urls = ["x-apple.systempreferences:com.apple.Network-Settings.extension",
                    "x-apple.systempreferences:com.apple.preference.network"]
        for u in urls { if let url = URL(string: u), NSWorkspace.shared.open(url) { return } }
    }

    private func showDetails() {
        let r = lastResponse
        let lines = [
            "Mode: \(r?.mode?.rawValue ?? "unknown")\(r?.enforcing == true ? " (enforcing)" : "")",
            "VPN: \(r?.tunnel ?? "unknown")\(r?.interface.map { " on \($0)" } ?? "")",
            "Rule set: \(r?.rules ?? "unknown")",
            "pf: \(r?.pfEnabled.map { $0 ? "enabled" : "disabled" } ?? "unknown")",
            "Endpoints: \((r?.endpoints ?? []).joined(separator: ", "))",
        ]
        let a = NSAlert()
        a.messageText = state.headline
        a.informativeText = lines.joined(separator: "\n")
        NSApp.activate(ignoringOtherApps: true)
        a.runModal()
    }
}

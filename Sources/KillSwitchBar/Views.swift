import AppKit
import KillSwitchClient

/// Status header: coloured dot, headline, detail. Colour is never the only signal (the text states it).
final class HeaderView: NSView {
    init(state: UIState) {
        super.init(frame: NSRect(x: 0, y: 0, width: 292, height: 46))
        let dot = NSView(frame: NSRect(x: 14, y: 26, width: 9, height: 9))
        dot.wantsLayer = true
        dot.layer?.cornerRadius = 4.5
        dot.layer?.backgroundColor = HeaderView.color(state.kind).cgColor
        addSubview(dot)
        let head = NSTextField(labelWithString: state.headline)
        head.font = .systemFont(ofSize: 13, weight: .semibold)
        head.frame = NSRect(x: 30, y: 22, width: 252, height: 18)
        let detail = NSTextField(labelWithString: state.detail)
        detail.font = .systemFont(ofSize: 11)
        detail.textColor = .secondaryLabelColor
        detail.lineBreakMode = .byTruncatingTail
        detail.frame = NSRect(x: 30, y: 6, width: 252, height: 15)
        addSubview(head); addSubview(detail)
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        setAccessibilityLabel(state.accessibilityLabel)
    }
    required init?(coder: NSCoder) { fatalError() }

    static func color(_ k: UIKind) -> NSColor {
        switch k {
        case .protected: return .systemGreen
        case .blocked: return .systemRed
        case .degraded, .paused: return .systemOrange
        case .off, .unreachable: return .systemGray
        }
    }
}

/// "If I am locked out…" window: the steps from RecoveryText, each command copyable.
final class RecoveryWindow: NSObject {
    nonisolated(unsafe) static var window: NSWindow?

    static func show() {
        if let w = window { w.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true); return }
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 330),
                         styleMask: [.titled, .closable], backing: .buffered, defer: false)
        w.title = "If I am locked out"
        w.isReleasedWhenClosed = false
        let stack = NSStackView()
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        for step in RecoveryText.steps {
            let title = NSTextField(labelWithString: step.title)
            title.font = .systemFont(ofSize: 12, weight: .semibold)
            let cmd = NSTextField(labelWithString: step.command)
            cmd.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
            cmd.isSelectable = true
            let copy = NSButton(title: "Copy", target: CopyHandler.shared, action: #selector(CopyHandler.copy(_:)))
            copy.bezelStyle = .rounded; copy.toolTip = step.command
            let row = NSStackView(views: [cmd, copy]); row.spacing = 8
            stack.addArrangedSubview(title); stack.addArrangedSubview(row)
        }
        let note = NSTextField(wrappingLabelWithString: RecoveryText.note)
        note.font = .systemFont(ofSize: 11); note.textColor = .secondaryLabelColor
        note.preferredMaxLayoutWidth = 520
        stack.addArrangedSubview(note)
        w.contentView = stack
        w.center()
        window = w
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

final class CopyHandler: NSObject {
    static let shared = CopyHandler()
    @objc func copy(_ sender: NSButton) {
        guard let c = sender.toolTip else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(c, forType: .string)
    }
}

import AppKit
import KillSwitchClient

/// Small floating window shown once per trial, because the menu is closed most of the time.
final class TrialPanel: NSObject {
    private var panel: NSPanel?
    private let label = NSTextField(labelWithString: "")
    private var shownForThisTrial = false
    var onKeep: () -> Void = {}
    var onRevert: () -> Void = {}

    func update(secondsLeft: Int?) {
        guard let left = secondsLeft else {
            shownForThisTrial = false
            panel?.orderOut(nil)
            return
        }
        label.stringValue = "Keep the kill switch? Reverting in \(Countdown.format(left))."
        if !shownForThisTrial { shownForThisTrial = true; show() }
    }

    private func show() {
        let p = panel ?? makePanel()
        panel = p
        if let screen = NSScreen.main {
            let f = screen.visibleFrame
            p.setFrameTopLeftPoint(NSPoint(x: f.maxX - p.frame.width - 16, y: f.maxY - 8))
        }
        p.orderFrontRegardless()
    }

    private func makePanel() -> NSPanel {
        let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 340, height: 96),
                        styleMask: [.titled, .utilityWindow, .nonactivatingPanel], backing: .buffered, defer: false)
        p.title = "Kill switch trial"
        p.level = .floating
        p.hidesOnDeactivate = false
        p.isReleasedWhenClosed = false
        label.font = .systemFont(ofSize: 13)
        label.setAccessibilityLabel("Keep the kill switch?")
        let keep = NSButton(title: "Keep", target: self, action: #selector(keepClicked))
        keep.keyEquivalent = "\r"
        let revert = NSButton(title: "Revert now…", target: self, action: #selector(revertClicked))
        let buttons = NSStackView(views: [keep, revert]); buttons.spacing = 8
        let stack = NSStackView(views: [label, buttons])
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 14, left: 16, bottom: 14, right: 16)
        p.contentView = stack
        return p
    }

    @objc private func keepClicked() { onKeep() }
    @objc private func revertClicked() { onRevert() }
}

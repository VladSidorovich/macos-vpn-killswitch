import AppKit
import KillSwitchClient
import KillSwitchCore

/// Turns menu clicks into daemon requests or password-prompted commands.
final class AppActions {
    private let client: DaemonClient
    private let controller: StatusController
    var pollNow: () -> Void = {}

    init(client: DaemonClient, controller: StatusController) {
        self.client = client
        self.controller = controller
    }

    func handle(_ action: MenuAction) {
        switch ActionMapper.plan(for: action, config: controller.config) {
        case .none: break
        case let .daemon(req): sendToDaemon(req)
        case let .privileged(p):
            if p == .emergencyRelease && !confirmEmergency() { return }
            AdminRunner.run(p, maxPause: controller.config.maxPauseSeconds) { [weak self] result in
                switch result {
                case .done: break
                case .cancelled: break                         // nothing changed
                case let .failed(msg): Self.alert("Could not complete the action", msg)
                }
                self?.pollNow()
            }
        }
    }

    private func sendToDaemon(_ req: IPCRequest) {
        DispatchQueue.global(qos: .userInitiated).async { [client] in
            var failure: String?
            do {
                let r = try client.send(req)
                if !r.ok { failure = r.error ?? "The daemon refused the request." }
            } catch let e as ClientError { failure = e.message } catch let e { failure = "\(e)" }
            DispatchQueue.main.async { [weak self] in
                if let f = failure { Self.alert("Could not complete the action", f) }
                self?.pollNow()
            }
        }
    }

    private func confirmEmergency() -> Bool {
        let a = NSAlert()
        a.messageText = "Stop the kill switch?"
        a.informativeText = "This stops the kill switch daemon and removes its rules, so traffic is no longer protected. Run scripts/install.sh to bring it back."
        a.addButton(withTitle: "Cancel")
        a.addButton(withTitle: "Stop and remove rules")
        a.alertStyle = .warning
        NSApp.activate(ignoringOtherApps: true)
        return a.runModal() == .alertSecondButtonReturn
    }

    static func alert(_ title: String, _ text: String) {
        let a = NSAlert()
        a.messageText = title
        a.informativeText = text
        a.alertStyle = .warning
        NSApp.activate(ignoringOtherApps: true)
        a.runModal()
    }
}

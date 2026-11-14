import Foundation
import KillSwitchCore

/// What a menu click turns into. Pure, so it can be tested without a GUI.
public enum ActionPlan: Equatable, Sendable {
    case daemon(IPCRequest)            // unprivileged: sent over the socket
    case privileged(PrivilegedAction)  // needs the administrator password prompt
    case none                          // handled locally by the app
}

public enum ActionMapper {
    public static func plan(for a: MenuAction, config: ConfigView) -> ActionPlan {
        switch a {
        case .turnOn: return .daemon(IPCRequest(verb: .on))                // permanent, no trial
        case .keep: return .daemon(IPCRequest(verb: .confirm))
        case .resume: return .daemon(IPCRequest(verb: .resume))
        case .turnOff, .revertNow:
            return config.locked ? .privileged(.off) : .daemon(IPCRequest(verb: .off))
        case .pause:
            return config.locked ? .privileged(.pause(seconds: MenuPlan.pauseSeconds))
                                 : .daemon(IPCRequest(verb: .pause, seconds: MenuPlan.pauseSeconds))
        case .emergency: return .privileged(.emergencyRelease)
        default: return .none
        }
    }
}

// MARK: Notifications

public struct AppNotification: Equatable, Sendable {
    public let title: String
    public let body: String
}

public enum NotificationPlanner {
    /// Notifications for a state change. The first state ever seen produces none.
    public static func events(from prev: UIState?, to new: UIState) -> [AppNotification] {
        guard let prev else { return [] }
        func n(_ t: String, _ b: String) -> [AppNotification] { [AppNotification(title: t, body: b)] }

        if new.kind == .unreachable && prev.kind != .unreachable {
            return n("Kill switch not reachable", "The daemon is not answering. Your protection state is unknown.")
        }
        if new.kind == .degraded && prev.kind != .degraded {
            return n("Kill switch needs attention", "Rules are not being enforced. Open the menu for details.")
        }
        if prev.kind == .protected && new.kind == .blocked {
            return n("VPN is down: internet blocked", "Connect the VPN to restore access.")
        }
        if prev.kind == .blocked && new.kind == .protected {
            return n("VPN connected", "Protected \(new.detail).")
        }
        if prev.trialSecondsLeft == nil, let left = new.trialSecondsLeft {
            return n("Kill switch trial started", "Protection reverts in \(Countdown.format(left)) unless you keep it.")
        }
        if prev.trialSecondsLeft != nil && new.trialSecondsLeft == nil && new.kind == .off {
            return n("Trial ended", "Protection is off.")
        }
        if prev.kind == .paused && new.kind != .paused && new.kind != .off && new.kind != .unreachable {
            return n("Pause ended", "Protection is back on.")
        }
        if new.kind == .off && prev.kind != .off && prev.kind != .unreachable && prev.trialSecondsLeft == nil {
            return n("Kill switch turned off", "Traffic is not protected.")
        }
        return []
    }
}

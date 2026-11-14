import Foundation
import KillSwitchCore

public enum MenuAction: String, Equatable, Sendable {
    case header, trialBanner, turnOn, turnOff, pause, resume, keep, revertNow
    case connectVPN, details, recovery, emergency, quit, separator
}

public struct MenuEntry: Equatable, Sendable {
    public var action: MenuAction
    public var title: String
    public var enabled: Bool
    /// True when the daemon will ask for an administrator password (locked config).
    public var needsAdmin: Bool
}

public struct ConfigView: Equatable, Sendable {
    public var locked: Bool
    public var maxPauseSeconds: Int
    public init(locked: Bool, maxPauseSeconds: Int) { self.locked = locked; self.maxPauseSeconds = maxPauseSeconds }
}

public enum MenuPlan {
    public static let pauseSeconds = 300

    public static func make(state: UIState, config: ConfigView) -> [MenuEntry] {
        func e(_ a: MenuAction, _ t: String, enabled: Bool = true, admin: Bool = false) -> MenuEntry {
            MenuEntry(action: a, title: t, enabled: enabled, needsAdmin: admin)
        }
        let sep = e(.separator, "")
        let reachable = state.kind != .unreachable
        var m: [MenuEntry] = [e(.header, state.headline)]

        if let left = state.trialSecondsLeft {
            m.append(e(.trialBanner, "Keep the kill switch? Reverting in \(Countdown.format(left))"))
            m.append(e(.keep, "Keep"))
            m.append(e(.revertNow, "Revert now…", admin: config.locked))
        }
        m.append(sep)

        switch state.kind {
        case .off:
            m.append(e(.turnOn, "Turn On", enabled: reachable))
        case .unreachable:
            m.append(e(.turnOn, "Turn On", enabled: false))
        default:
            m.append(e(.turnOff, config.locked ? "Turn Off…" : "Turn Off", admin: config.locked))
        }
        if state.kind == .paused {
            m.append(e(.resume, "Resume now"))
        } else if (state.kind == .protected || state.kind == .blocked || state.kind == .degraded),
                  config.maxPauseSeconds >= pauseSeconds {
            m.append(e(.pause, config.locked ? "Pause for 5 minutes…" : "Pause for 5 minutes", admin: config.locked))
        }
        if reachable && !state.tunnelConnected {
            m.append(e(.connectVPN, "Connect VPN…"))
        }
        m.append(sep)
        m.append(e(.details, "Status details…", enabled: reachable))
        m.append(e(.recovery, "If I am locked out…"))
        if state.kind == .unreachable || state.kind == .degraded {
            m.append(e(.emergency, "Emergency release…", admin: true))
        }
        m.append(e(.quit, "Quit menu"))
        return m
    }
}

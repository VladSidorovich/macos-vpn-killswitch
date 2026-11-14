import Foundation
import KillSwitchCore

public enum UIKind: String, Equatable, Sendable {
    case unreachable, degraded, paused, off, blocked, protected
}

/// What the app knows at one moment: the last answer (or error) and how fresh it is.
public struct Snapshot: Sendable {
    public var response: IPCResponse?
    public var error: ClientError?
    /// Seconds since the last good answer; nil if there has never been one.
    public var ageOfLastGood: TimeInterval?
    /// Consecutive polls in which the answer looked inconsistent (debounce for "degraded").
    public var inconsistentStreak: Int
    public var now: Date

    public init(response: IPCResponse?, error: ClientError? = nil, ageOfLastGood: TimeInterval? = 0,
                inconsistentStreak: Int = 0, now: Date = Date()) {
        self.response = response
        self.error = error
        self.ageOfLastGood = ageOfLastGood
        self.inconsistentStreak = inconsistentStreak
        self.now = now
    }
}

public struct UIState: Equatable, Sendable {
    public var kind: UIKind
    /// Short text next to the menu-bar icon (countdown), if any.
    public var title: String?
    public var headline: String
    public var detail: String
    public var tunnelConnected: Bool
    /// Seconds left in an unconfirmed trial; overlays any kind.
    public var trialSecondsLeft: Int?
    public var accessibilityLabel: String
}

public enum Countdown {
    public static func format(_ seconds: Int) -> String {
        let s = max(0, seconds)
        return s < 60 ? "\(s)s" : String(format: "%d:%02d", s / 60, s % 60)
    }
}

public enum UIStateDeriver {
    public static let staleAfter: TimeInterval = 6
    public static let degradedPolls = 2

    /// True when the daemon claims to enforce but the pieces do not add up.
    public static func looksInconsistent(_ r: IPCResponse) -> Bool {
        guard r.enforcing == true, r.pauseUntil == nil else { return false }
        if r.pfEnabled == false { return true }
        if let p = r.problems, !p.isEmpty { return true }
        if r.rules == "emergency" { return true }
        if r.rules == "none" { return true }
        if r.tunnel == "unknown" { return true }
        let connected = r.tunnel == "connected"
        if connected && r.rules != "up" { return true }
        if !connected && r.rules == "up" { return true }
        return false
    }

    public static func derive(_ s: Snapshot) -> UIState {
        let name = "VPN kill switch"
        // 1. unreachable: error, no answer, or stale
        if s.error != nil || s.response == nil || (s.ageOfLastGood ?? .infinity) > staleAfter {
            let why = s.error?.message ?? "no recent answer"
            return UIState(kind: .unreachable, title: nil, headline: "Daemon not reachable", detail: why,
                           tunnelConnected: false, trialSecondsLeft: nil,
                           accessibilityLabel: "\(name): daemon not reachable")
        }
        let r = s.response!
        let trial = r.trialDeadline.map { max(0, Int($0 - s.now.timeIntervalSince1970)) }
        let connected = r.tunnel == "connected"
        var st: UIState
        if r.enforcing == true && looksInconsistent(r) && s.inconsistentStreak >= degradedPolls {
            st = UIState(kind: .degraded, title: nil, headline: "Attention: rules not enforced",
                         detail: r.problems?.first
                                ?? (r.rules == "emergency" ? "emergency rules are loaded; the normal ruleset failed"
                                    : r.pfEnabled == false ? "pf is disabled; the daemon repairs this within a few seconds"
                                    : "rules do not match the VPN state"),
                         tunnelConnected: connected, trialSecondsLeft: nil,
                         accessibilityLabel: "\(name): attention needed")
        } else if let p = r.pauseUntil, p > s.now.timeIntervalSince1970 {
            let left = Int(p - s.now.timeIntervalSince1970)
            st = UIState(kind: .paused, title: Countdown.format(left),
                         headline: "Paused, resumes in \(Countdown.format(left))",
                         detail: "Traffic is not filtered while paused",
                         tunnelConnected: connected, trialSecondsLeft: nil,
                         accessibilityLabel: "\(name): paused, resumes in \(left) seconds")
        } else if r.mode == .off {
            st = UIState(kind: .off, title: nil, headline: "Off", detail: "Traffic is not protected",
                         tunnelConnected: connected, trialSecondsLeft: nil, accessibilityLabel: "\(name): off")
        } else if connected && r.rules == "up" && r.pfEnabled != false {
            st = UIState(kind: .protected, title: nil, headline: "Protected",
                         detail: "via \(r.interface ?? "tunnel")", tunnelConnected: true,
                         trialSecondsLeft: nil, accessibilityLabel: "\(name): protected")
        } else {
            let connecting = r.tunnel == "connecting"
            st = UIState(kind: .blocked, title: nil,
                         headline: connecting ? "Blocked: VPN connecting…" : "Blocked: VPN is down",
                         detail: "Internet is blocked until the VPN is connected",
                         tunnelConnected: connected, trialSecondsLeft: nil,
                         accessibilityLabel: "\(name): blocking, VPN is down")
        }
        if let t = trial {
            st.trialSecondsLeft = t
            st.title = Countdown.format(t)
            st.accessibilityLabel += ", trial, reverting in \(t) seconds"
        }
        return st
    }
}

import Foundation

public enum PrivilegedAction: Equatable, Sendable {
    case off
    case pause(seconds: Int)
    case emergencyRelease
}

public enum PrivilegedError: Error, Equatable {
    case badPause
    case unsafePath(String)
}

/// Builds the one-line shell command and AppleScript that a password prompt runs as root.
/// Every string is a constant; the only variable part is a validated integer.
public enum PrivilegedCommand {
    public static let label = "io.github.vladsidorovich.vpn-killswitch"
    public static let ksctl = "/usr/local/bin/ksctl"
    public static let panic = "/usr/local/libexec/vpn-killswitch/panic.sh"

    public static func shellCommand(for a: PrivilegedAction, maxPause: Int) throws -> String {
        switch a {
        case .off: return "\(ksctl) off"
        case let .pause(s):
            guard s > 0, s <= maxPause, s <= 86_400 else { throw PrivilegedError.badPause }
            return "\(ksctl) pause \(s)"
        case .emergencyRelease:
            // Stop the daemon first, otherwise it reloads the rules within 30 s.
            return "/bin/launchctl bootout system/\(label); \(panic)"
        }
    }

    public static func prompt(for a: PrivilegedAction) -> String {
        switch a {
        case .off: return "VPN Kill Switch wants to turn protection off."
        case .pause: return "VPN Kill Switch wants to pause protection for 5 minutes."
        case .emergencyRelease:
            return "VPN Kill Switch wants to stop the kill switch daemon and remove its rules. Run the install script to restore it."
        }
    }

    public static func appleScript(for a: PrivilegedAction, maxPause: Int) throws -> String {
        let cmd = try shellCommand(for: a, maxPause: maxPause)
        let p = prompt(for: a)
        precondition(!cmd.contains("\"") && !cmd.contains("\\") && !p.contains("\"") && !p.contains("\\"))
        return "do shell script \"\(cmd)\" with prompt \"\(p)\" with administrator privileges"
    }

    /// The file and every parent directory must be owned by root and not group/other-writable.
    /// `stat` is injectable so this can be tested without touching the real file system.
    public static func pathIsSafe(_ path: String,
                                  stat: (String) -> (uid: UInt32, mode: UInt16)? = realStat) -> Bool {
        var p = path
        while true {
            guard let s = stat(p), s.uid == 0, s.mode & 0o022 == 0 else { return false }
            if p == "/" { return true }
            p = (p as NSString).deletingLastPathComponent
            if p.isEmpty { p = "/" }
        }
    }

    public static func realStat(_ path: String) -> (uid: UInt32, mode: UInt16)? {
        guard let a = try? FileManager.default.attributesOfItem(atPath: path),
              let uid = a[.ownerAccountID] as? NSNumber, let mode = a[.posixPermissions] as? NSNumber else { return nil }
        return (uid.uint32Value, mode.uint16Value)
    }
}

public enum RecoveryText {
    public struct Step: Equatable, Sendable { public let title: String; public let command: String }

    public static let steps: [Step] = [
        Step(title: "Turn it off normally", command: "sudo ksctl off"),
        Step(title: "Daemon stuck? Stop it, then remove the rules",
             command: "sudo launchctl bootout system/\(PrivilegedCommand.label)"),
        Step(title: "Remove the rules", command: "sudo \(PrivilegedCommand.panic)"),
        Step(title: "Last resort: switch pf off completely", command: "sudo pfctl -d"),
    ]

    public static let note = "A reboot alone does not help while the daemon is installed and the mode is on: it starts again and reloads the rules. Stop the daemon first. In Recovery OS you can delete /Library/LaunchDaemons/\(PrivilegedCommand.label).plist."
}

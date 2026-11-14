import Foundation
import KillSwitchClient

enum AdminResult: Equatable {
    case done, cancelled
    case failed(String)
}

/// Runs one constant command as root through the system password prompt (osascript).
/// The dialog is the system's own; this app never sees the password.
enum AdminRunner {
    static func run(_ action: PrivilegedAction, maxPause: Int, completion: @escaping (AdminResult) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let r = execute(action, maxPause: maxPause)
            DispatchQueue.main.async { completion(r) }
        }
    }

    static func execute(_ action: PrivilegedAction, maxPause: Int) -> AdminResult {
        // Never hand a user-writable program to a root prompt.
        let tool = action == .emergencyRelease ? PrivilegedCommand.panic : PrivilegedCommand.ksctl
        guard PrivilegedCommand.pathIsSafe(tool) else {
            return .failed("\(tool) is missing or not owned by root. Reinstall with scripts/install.sh.")
        }
        let script: String
        do { script = try PrivilegedCommand.appleScript(for: action, maxPause: maxPause) }
        catch { return .failed("Invalid action.") }

        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-e", script]
        let err = Pipe()
        p.standardError = err
        p.standardOutput = Pipe()
        do { try p.run() } catch { return .failed("Could not start osascript: \(error)") }
        let data = err.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        if p.terminationStatus == 0 { return .done }
        let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        if text.contains("-128") || text.localizedCaseInsensitiveContains("user canceled") { return .cancelled }
        return .failed(text.isEmpty ? "The command failed." : text)
    }
}

import Foundation

package func log(_ msg: String) {
    let f = DateFormatter()
    f.dateFormat = "yyyy-MM-dd HH:mm:ss"
    FileHandle.standardError.write(Data("\(f.string(from: Date())) \(msg)\n".utf8))
}

package struct ShellResult {
    package let status: Int32
    package let out: String
    package let err: String
    package init(status: Int32, out: String, err: String) { self.status = status; self.out = out; self.err = err }
}

package func shell(_ path: String, _ args: [String], input: String? = nil) -> ShellResult {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: path)
    p.arguments = args
    let o = Pipe(), e = Pipe()
    let i: Pipe? = input != nil ? Pipe() : nil
    p.standardOutput = o
    p.standardError = e
    if let i { p.standardInput = i }
    // Close every pipe end explicitly: relying on Pipe deinit leaked
    // descriptors in this long-running daemon until posix_spawn failed.
    defer {
        for h in [o.fileHandleForReading, o.fileHandleForWriting,
                  e.fileHandleForReading, e.fileHandleForWriting] { try? h.close() }
        if let i { try? i.fileHandleForReading.close(); try? i.fileHandleForWriting.close() }
    }
    do { try p.run() } catch { return ShellResult(status: 127, out: "", err: "\(error)") }
    // Drop our copy of the child's write ends so reads see EOF.
    try? o.fileHandleForWriting.close()
    try? e.fileHandleForWriting.close()
    if let input, let i {
        try? i.fileHandleForReading.close()
        i.fileHandleForWriting.write(Data(input.utf8))
        try? i.fileHandleForWriting.close()
    }
    let od = o.fileHandleForReading.readDataToEndOfFile()
    let ed = e.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return ShellResult(status: p.terminationStatus,
                       out: String(decoding: od, as: UTF8.self),
                       err: String(decoding: ed, as: UTF8.self))
}

/// The only place that talks to pf. Rule text never comes from clients.
package protocol PFControlling: AnyObject {
    func isEnabled() -> Bool
    func enable() -> String?               // returns the enable token
    func release(token: String)
    func load(anchor: String, rules: String) -> Bool
    func flush(anchor: String)
    func anchorHasRules(anchor: String) -> Bool
    func mainRules() -> String            // `pfctl -sr`, the main ruleset
}

package final class RealPF: PFControlling {
    private let pfctl = "/sbin/pfctl"
    package init() {}

    package func isEnabled() -> Bool { shell(pfctl, ["-s", "info"]).out.contains("Status: Enabled") }

    package func enable() -> String? {
        let r = shell(pfctl, ["-E"])
        let text = r.err + r.out
        guard let range = text.range(of: #"Token : *[0-9]+"#, options: .regularExpression) else { return nil }
        return String(text[range]).split(separator: " ").last.map(String.init)
    }

    package func release(token: String) { _ = shell(pfctl, ["-X", token]) }

    package func load(anchor: String, rules: String) -> Bool {
        let r = shell(pfctl, ["-a", anchor, "-f", "-"], input: rules)
        if r.status != 0 { log("pfctl load failed: \(r.err.trimmingCharacters(in: .whitespacesAndNewlines))") }
        return r.status == 0
    }

    package func flush(anchor: String) { _ = shell(pfctl, ["-a", anchor, "-F", "all"]) }

    package func mainRules() -> String { shell(pfctl, ["-sr"]).out }

    package func anchorHasRules(anchor: String) -> Bool {
        !shell(pfctl, ["-a", anchor, "-sr"]).out.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

/// Logs what it would do. Lets the whole daemon run as an ordinary user.
package final class DryPF: PFControlling {
    private var enabled = false
    private var rules: [String: String] = [:]
    package init() {}

    package func isEnabled() -> Bool { enabled }
    package func enable() -> String? { enabled = true; log("[dry] pfctl -E"); return "0" }
    package func release(token: String) { enabled = false; log("[dry] pfctl -X \(token)") }
    package func load(anchor: String, rules text: String) -> Bool {
        rules[anchor] = text
        log("[dry] pfctl -a \(anchor) -f -\n" + text.split(separator: "\n").map { "      " + $0 }.joined(separator: "\n"))
        return true
    }
    package func flush(anchor: String) { rules[anchor] = nil; log("[dry] pfctl -a \(anchor) -F all") }
    package func anchorHasRules(anchor: String) -> Bool { rules[anchor] != nil }
    package func mainRules() -> String { "scrub-anchor \"com.apple/*\"\nanchor \"com.apple/*\" all\n" }
}

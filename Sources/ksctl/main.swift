import Foundation
import KillSwitchCore
import KillSwitchClient

// ksctl: talks to killswitchd over its unix socket, and renders rulesets offline.
//   ksctl status|on|confirm|off|resume [--socket PATH]
//   ksctl on [--trial SECONDS] [--force]
//   ksctl pause SECONDS
//   ksctl render --config FILE [--down] [--tunnel-if ppp0] [--endpoint IP]...   (touches nothing)

func fail(_ msg: String) -> Never {
    FileHandle.standardError.write(Data((msg + "\n").utf8))
    exit(2)
}

let usage = """
usage: ksctl status | on [--trial SECONDS] [--force] | confirm | off | pause SECONDS | resume   [--socket PATH]
       ksctl render --config FILE [--down] [--tunnel-if IF] [--endpoint IP]...
"""

var args = Array(CommandLine.arguments.dropFirst())
guard let sub = args.first else { fail(usage) }
args.removeFirst()

func takeValue(_ flag: String) -> String? {
    guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
    let v = args[i + 1]
    args.removeSubrange(i...(i + 1))
    return v
}
func takeFlag(_ flag: String) -> Bool {
    guard let i = args.firstIndex(of: flag) else { return false }
    args.remove(at: i)
    return true
}

// MARK: render (offline)

if sub == "render" {
    var path: String?
    var down = false
    var tunnelIf: String? = "ppp0"
    var endpoints: [String] = []
    var i = 0
    while i < args.count {
        switch args[i] {
        case "--config": i += 1; path = i < args.count ? args[i] : nil
        case "--down": down = true
        case "--tunnel-if": i += 1; tunnelIf = i < args.count ? args[i] : nil
        case "--endpoint": i += 1; if i < args.count { endpoints.append(args[i]) }
        default: fail("unknown argument \(args[i])")
        }
        i += 1
    }
    guard let path else { fail("--config is required") }
    guard let data = FileManager.default.contents(atPath: path) else { fail("cannot read \(path)") }
    let config: Config
    do { config = try JSONDecoder().decode(Config.self, from: data) } catch { fail("bad config: \(error)") }
    let problems = config.validate()
    if !problems.isEmpty { fail("invalid config:\n" + problems.map { "  - " + $0 }.joined(separator: "\n")) }
    do {
        let r = try RulesetBuilder.build(config: config, tunnelInterface: tunnelIf, endpointIPs: endpoints, tunnelUp: !down)
        print(r.text, terminator: "")
    } catch { fail("\(error)") }
    exit(0)
}

// MARK: client

let socketPath = takeValue("--socket") ?? "/var/run/vpn-killswitch.sock"
var req: IPCRequest
switch sub {
case "status": req = IPCRequest(verb: .status)
case "on":
    let trial = takeValue("--trial").flatMap { Int($0) }
    req = IPCRequest(verb: .on, trialSeconds: trial, force: takeFlag("--force"))
case "confirm": req = IPCRequest(verb: .confirm)
case "off": req = IPCRequest(verb: .off)
case "resume": req = IPCRequest(verb: .resume)
case "pause":
    guard let s = args.first.flatMap({ Int($0) }) else { fail("pause needs SECONDS") }
    req = IPCRequest(verb: .pause, seconds: s)
default: fail(usage)
}

let resp: IPCResponse
do { resp = try DaemonClient(path: socketPath).send(req) }
catch let e as ClientError { fail(e.message) }
catch { fail("\(error)") }
if !resp.ok { fail("error: \(resp.error ?? "unknown")") }

func when(_ t: Double?) -> String {
    guard let t else { return "-" }
    let left = Int(t - Date().timeIntervalSince1970)
    return left > 0 ? "in \(left)s" : "now"
}
print("mode:      \(resp.mode?.rawValue ?? "?")\(resp.enforcing == true ? " (enforcing)" : "")")
print("tunnel:    \(resp.tunnel ?? "?")\(resp.interface.map { " on \($0)" } ?? "")")
print("rules:     \(resp.rules ?? "?") set, pf \(resp.pfEnabled == true ? "enabled" : "disabled")")
print("endpoints: \((resp.endpoints ?? []).joined(separator: ", "))")
if resp.trialDeadline != nil { print("trial:     reverts \(when(resp.trialDeadline)) unless `ksctl confirm`") }
if resp.pauseUntil != nil { print("paused:    until \(when(resp.pauseUntil))") }

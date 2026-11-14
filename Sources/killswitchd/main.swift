import Foundation
import SystemConfiguration
import KillSwitchCore
import KillSwitchDaemon

// killswitchd: keeps the pf anchor in sync with the VPN state.
//   killswitchd --config FILE [--state-dir DIR] [--socket PATH] [--dry-run]
// --dry-run logs the pfctl commands instead of running them and needs no root.

func usage() -> Never {
    FileHandle.standardError.write(Data("usage: killswitchd --config FILE [--state-dir DIR] [--socket PATH] [--dry-run]\n".utf8))
    exit(2)
}

var configPath: String?
var stateDir = "/var/db/vpn-killswitch"
var socketPath: String?
var dryRun = false
var argv = Array(CommandLine.arguments.dropFirst())
while !argv.isEmpty {
    let a = argv.removeFirst()
    switch a {
    case "--config": configPath = argv.isEmpty ? nil : argv.removeFirst()
    case "--state-dir": stateDir = argv.isEmpty ? stateDir : argv.removeFirst()
    case "--socket": socketPath = argv.isEmpty ? nil : argv.removeFirst()
    case "--dry-run": dryRun = true
    default: usage()
    }
}
signal(SIGPIPE, SIG_IGN)   // a client that disconnects early must not kill the daemon
guard let configPath else { usage() }
if !dryRun && geteuid() != 0 { log("must run as root (or use --dry-run)"); exit(1) }

guard let data = FileManager.default.contents(atPath: configPath) else { log("cannot read \(configPath)"); exit(1) }
let config: Config
do { config = try JSONDecoder().decode(Config.self, from: data) } catch { log("bad config: \(error)"); exit(1) }
let problems = config.validate()
if !problems.isEmpty { log("invalid config: " + problems.joined(separator: "; ")); exit(1) }

try? FileManager.default.createDirectory(atPath: stateDir, withIntermediateDirectories: true,
                                         attributes: [.posixPermissions: 0o755])
let paths = Paths(
    stateFile: stateDir + "/state.json",
    endpointsFile: stateDir + "/endpoints.json",
    tokenFile: dryRun ? stateDir + "/token" : "/var/run/vpn-killswitch.token",
    socket: socketPath ?? (dryRun ? stateDir + "/ks.sock" : "/var/run/vpn-killswitch.sock"))

let loadedState = StateLoading.load(data: FileManager.default.contents(atPath: paths.stateFile), locked: config.locked)
if let note = loadedState.note { log(note) }
let persisted = loadedState.state
let cached = readJSON([String].self, from: paths.endpointsFile) ?? []
let seed = Array(Set(cached + config.servers.filter { RouteParser.isIPv4($0) })).sorted()

let pf: PFControlling = dryRun ? DryPF() : RealPF()
let daemon = Daemon(config: config, persisted: persisted, endpoints: seed, pf: pf, paths: paths)
log("killswitchd starting (mode \(persisted.mode.rawValue), service \(config.serviceName), \(dryRun ? "DRY RUN" : "live"))")

let server = IPCServer(path: paths.socket, daemon: daemon, rootMode: !dryRun)
guard server.start() else { exit(1) }

daemon.start()

// Network changes: debounce, then reconcile.
final class Box { let f: () -> Void; init(_ f: @escaping () -> Void) { self.f = f } }
nonisolated(unsafe) var pending = false
let box = Unmanaged.passRetained(Box {
    if pending { return }
    pending = true
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { pending = false; daemon.reconcile("network change") }
})
var ctx = SCDynamicStoreContext(version: 0, info: box.toOpaque(), retain: nil, release: nil, copyDescription: nil)
let store = SCDynamicStoreCreate(nil, "killswitchd" as CFString, { _, _, info in
    guard let info else { return }
    Unmanaged<Box>.fromOpaque(info).takeUnretainedValue().f()
}, &ctx)
if let store {
    let patterns = ["State:/Network/Global/IPv4", "State:/Network/Interface",
                    "State:/Network/Service/.*/IPv4", "State:/Network/Service/.*/PPP",
                    "State:/Network/Service/.*/VPN"] as CFArray
    SCDynamicStoreSetNotificationKeys(store, nil, patterns)
    // dispatchMain() does not service CFRunLoop sources, so deliver on the main dispatch queue.
    if !SCDynamicStoreSetDispatchQueue(store, DispatchQueue.main) {
        log("could not attach network events; relying on the periodic check")
    }
} else {
    log("SCDynamicStore unavailable; relying on the periodic check")
}

// 1 s: pause/trial expiry. 30 s: full reconcile, which also repairs pf drift.
let quick = DispatchSource.makeTimerSource(queue: .main)
quick.schedule(deadline: .now() + 1, repeating: 1)
quick.setEventHandler { daemon.quickTick() }
quick.resume()
let integrity = DispatchSource.makeTimerSource(queue: .main)
integrity.schedule(deadline: .now() + 30, repeating: 30)
integrity.setEventHandler { daemon.reconcile("integrity check") }
integrity.resume()
// 5 s: cheap pf drift check (pf disabled, anchor emptied) and main-ruleset tamper report.
let cheap = DispatchSource.makeTimerSource(queue: .main)
cheap.schedule(deadline: .now() + 5, repeating: 5)
cheap.setEventHandler { daemon.cheapCheck() }
cheap.resume()

// Stopping does not remove the rules (fail-closed). `ksctl off` or panic.sh does.
nonisolated(unsafe) var signalSources: [DispatchSourceSignal] = []
for sig in [SIGTERM, SIGINT] {
    signal(sig, SIG_IGN)
    let s = DispatchSource.makeSignalSource(signal: sig, queue: .main)
    s.setEventHandler { log("signal \(sig): exiting; rules stay loaded"); exit(0) }
    s.resume()
    signalSources.append(s)
}

dispatchMain()

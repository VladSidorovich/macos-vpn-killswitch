import AppKit
import KillSwitchClient
import KillSwitchCore

// KillSwitchBar: menu-bar client for killswitchd. Unprivileged; it never runs pfctl and never sends rule text.
//   KillSwitchBar [--socket PATH] [--config FILE] [--demo] [--demo-state NAME-PREFIX]
// --demo cycles through fixture states so every icon and menu can be checked without a daemon.

var socketPath = "/var/run/vpn-killswitch.sock"
var demo = false
var demoPin: String?
var configPath = "/Library/Application Support/VPNKillSwitch/config.json"
var args = Array(CommandLine.arguments.dropFirst())
while !args.isEmpty {
    let a = args.removeFirst()
    if a == "--socket", !args.isEmpty { socketPath = args.removeFirst() }
    else if a == "--config", !args.isEmpty { configPath = args.removeFirst() }
    else if a == "--demo" { demo = true }
    else if a == "--demo-state", !args.isEmpty { demo = true; demoPin = args.removeFirst() }
}

func readConfigView() -> ConfigView {
    if let d = FileManager.default.contents(atPath: configPath), let c = try? JSONDecoder().decode(Config.self, from: d) {
        return ConfigView(locked: c.locked, maxPauseSeconds: c.maxPauseSeconds)
    }
    return ConfigView(locked: true, maxPauseSeconds: 1800)      // assume the stricter setting
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)                              // no Dock icon, also when run bare

let initial = UIStateDeriver.derive(Snapshot(response: nil, error: .timeout, ageOfLastGood: nil))
let controller = StatusController(initial: initial, config: readConfigView())

nonisolated(unsafe) var keepAlive: [AnyObject] = []
if demo {
    let now = Date().timeIntervalSince1970
    func r(_ build: (inout IPCResponse) -> Void) -> IPCResponse {
        var x = IPCResponse(ok: true); x.mode = .on; x.enforcing = true; x.tunnel = "connected"
        x.interface = "ppp0"; x.rules = "up"; x.pfEnabled = true; x.endpoints = ["203.0.113.10"]
        build(&x); return x
    }
    let states: [(String, IPCResponse?, ClientError?, Int)] = [
        ("protected", r { _ in }, nil, 0),
        ("blocked: VPN down", r { $0.tunnel = "disconnected"; $0.interface = nil; $0.rules = "down" }, nil, 0),
        ("blocked: connecting", r { $0.tunnel = "connecting"; $0.interface = nil; $0.rules = "down" }, nil, 0),
        ("trial pending", r { $0.trialDeadline = now + 45 }, nil, 0),
        ("paused", r { $0.enforcing = false; $0.rules = "none"; $0.pauseUntil = now + 240 }, nil, 0),
        ("off", r { $0.mode = .off; $0.enforcing = false; $0.rules = "none" }, nil, 0),
        ("degraded", r { $0.rules = "none"; $0.pfEnabled = false }, nil, 2),
        ("unreachable", nil, .timeout, 0),
    ]
    var i = demoPin.flatMap { pin in states.firstIndex { $0.0.hasPrefix(pin) } } ?? 0
    let pinned = demoPin != nil
    func show() {
        let (name, resp, err, streak) = states[i % states.count]
        controller.footer = "Demo state: \(name)"
        controller.lastResponse = resp
        controller.update(UIStateDeriver.derive(Snapshot(response: resp, error: err, ageOfLastGood: resp == nil ? nil : 0,
                                                         inconsistentStreak: streak, now: Date())))
        FileHandle.standardError.write(Data("demo: \(name)\n".utf8))
        if !pinned { i += 1 }
    }
    show()
    keepAlive.append(Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { _ in show() })
} else {
    let notifier = Notifier()
    let trialPanel = TrialPanel()
    let actions = AppActions(client: DaemonClient(path: socketPath), controller: controller)
    controller.perform = { actions.handle($0) }
    trialPanel.onKeep = { actions.handle(.keep) }
    trialPanel.onRevert = { actions.handle(.revertNow) }
    var previous: UIState?
    let poller = Poller(client: DaemonClient(path: socketPath)) { state, response in
        controller.lastResponse = response
        controller.update(state)
        for n in NotificationPlanner.events(from: previous, to: state) { notifier.post(n) }
        trialPanel.update(secondsLeft: state.trialSecondsLeft)
        previous = state
    }
    actions.pollNow = { poller.poll() }
    poller.start()
    keepAlive.append(contentsOf: [poller, actions, notifier, trialPanel] as [AnyObject])
}
app.run()

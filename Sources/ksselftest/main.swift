import Foundation
import KillSwitchCore
import KillSwitchClient
import KillSwitchDaemon
import Darwin

// Plain self-test runner: `swift run ksselftest`. Exits non-zero on any failure.

nonisolated(unsafe) var failures = 0
nonisolated(unsafe) var checks = 0

func check(_ ok: Bool, _ msg: @autoclosure () -> String = "", line: Int = #line) {
    checks += 1
    if !ok { failures += 1; print("  FAIL line \(line): \(msg())") }
}

func throwsError<E: Error & Equatable>(_ expected: E, _ body: () throws -> Void, line: Int = #line) {
    do { try body(); check(false, "expected \(expected), nothing thrown", line: line) }
    catch let e as E { check(e == expected, "expected \(expected), got \(e)", line: line) }
    catch { check(false, "unexpected error \(error)", line: line) }
}

func throwsAny(_ body: () throws -> Void, line: Int = #line) {
    do { try body(); check(false, "expected a throw", line: line) } catch { check(true) }
}

func test(_ name: String, _ body: () throws -> Void) {
    let before = failures
    do { try body() } catch { failures += 1; print("  FAIL: threw \(error)") }
    print((failures == before ? "ok   " : "FAIL ") + name)
}

let uuid = "00000000-0000-4000-8000-000000000001"

func makeConfig(locked: Bool = true, exempt: [String] = [], lan: Bool = false, dns: EndpointDNS = .resolver) -> Config {
    Config(serviceUUID: uuid, serviceName: "My VPN", servers: ["vpn.example.com"],
           endpointDNS: dns, resolvers: ["192.0.2.53"], exemptDestinations: exempt,
           allowLAN: lan, locked: locked)
}

let listOutput = """
Available network connection services in the current set (*=enabled):
* (Disconnected)   2E9757FF-FC6C-487A-AA6A-4C1B698375C9 PPP --> USB Controls "USB Controls 2"                 [PPP:Modem]
* (Connected)      00000000-0000-4000-8000-000000000001 PPP --> L2TP       "My VPN"                        [PPP:L2TP]
* (Disconnected)   E9FB10DA-E0A3-46B5-8C89-FCEE56E0E4CB VPN (su.ffg.happ)  "Happ"                           [VPN:su.ffg.happ]
"""

let statusOutput = """
Connected
Extended Status <dictionary> {
  IPv4 : <dictionary> {
    InterfaceName : ppp0
    Router : 192.0.2.1
  }
}
"""

let ips = ["203.0.113.10"]

// MARK: Ruleset

test("ruleset: tunnel up passes on tunnel, DNS closed") {
    let r = try RulesetBuilder.build(config: makeConfig(), tunnelInterface: "ppp0", endpointIPs: ips, tunnelUp: true)
    check(r.text.contains("pass out quick on ppp0 all keep state (if-bound)"))
    check(r.text.contains("table <ks_endpoints> persist { 203.0.113.10 }"))
    check(r.text.contains("table <ks_dns> persist\n"))
}

test("ruleset: tunnel down drops tunnel pass, opens DNS to resolvers") {
    let r = try RulesetBuilder.build(config: makeConfig(), tunnelInterface: nil, endpointIPs: ips, tunnelUp: false)
    check(!r.text.contains("on ppp0"))
    check(r.text.contains("table <ks_dns> persist { 192.0.2.53 }"))
}

test("ruleset: endpointDNS=none never opens DNS") {
    let r = try RulesetBuilder.build(config: makeConfig(dns: .none), tunnelInterface: nil, endpointIPs: ips, tunnelUp: false)
    check(r.text.contains("table <ks_dns> persist\n"))
}

test("ruleset: every rule is quick, final rule is the block") {
    let r = try RulesetBuilder.build(config: makeConfig(), tunnelInterface: "ppp0", endpointIPs: ips, tunnelUp: true)
    let lines = r.text.split(separator: "\n")
    check(lines.last == "block return out quick log all")
    for l in lines where l.hasPrefix("pass") || l.hasPrefix("block") { check(l.contains(" quick "), String(l)) }
}

test("ruleset: L2TP covers IKE, NAT-T, L2TP, ESP") {
    let r = try RulesetBuilder.build(config: makeConfig(), tunnelInterface: nil, endpointIPs: ips, tunnelUp: false)
    check(r.text.contains("port { 500 4500 1701 }"))
    check(r.text.contains("proto esp to <ks_endpoints>"))
}

test("ruleset: exempt and LAN rules only when configured") {
    let plain = try RulesetBuilder.build(config: makeConfig(), tunnelInterface: nil, endpointIPs: [], tunnelUp: false)
    check(!plain.text.contains("<ks_exempt> keep state"))
    check(!plain.text.contains("pass out quick to {"))   // LAN rule; the DHCP rule lists private ranges too
    let rich = try RulesetBuilder.build(config: makeConfig(exempt: ["198.51.100.7"], lan: true), tunnelInterface: nil, endpointIPs: [], tunnelUp: false)
    check(rich.text.contains("pass out quick to <ks_exempt> keep state (if-bound)"))
    check(rich.text.contains("pass out quick to { 10.0.0.0/8"))
}

test("ruleset: rejects injection through interface and addresses") {
    throwsAny { _ = try RulesetBuilder.build(config: makeConfig(), tunnelInterface: "ppp0; pass all", endpointIPs: [], tunnelUp: true) }
    throwsAny { _ = try RulesetBuilder.build(config: makeConfig(), tunnelInterface: "ppp0", endpointIPs: ["1.2.3.4 } pass out all {"], tunnelUp: true) }
}

// MARK: Config

test("config: valid config has no problems") { check(makeConfig().validate().isEmpty) }

test("config: catches bad uuid, empty servers, missing resolvers") {
    var c = makeConfig()
    c.serviceUUID = "nope"; c.servers = []; c.resolvers = []
    check(c.validate().count == 3, "\(c.validate())")
}

test("config: decodes with defaults") {
    let json = #"{"serviceUUID":"\#(uuid)","serviceName":"My VPN","servers":["203.0.113.10"],"resolvers":["192.0.2.53"]}"#
    let c = try JSONDecoder().decode(Config.self, from: Data(json.utf8))
    check(c.locked && !c.allowLAN)
    check(c.validate().isEmpty)
}

// MARK: Matcher

test("matcher: parses scutil --nc list") {
    let s = VPNMatcher.parseList(listOutput)
    check(s.count == 3)
    check(s.first { $0.name == "My VPN" }?.status == .connected)
}

test("matcher: matches by UUID only, ignores Happ") {
    let s = VPNMatcher.parseList(listOutput)
    check(VPNMatcher.tunnelState(services: s, serviceUUID: uuid, statusOutput: statusOutput) == TunnelState(status: .connected, interface: "ppp0"))
    check(VPNMatcher.tunnelState(services: s, serviceUUID: "E9FB10DA-E0A3-46B5-8C89-FCEE56E0E4CC", statusOutput: nil) == nil)
}

test("matcher: disconnected service has no interface") {
    let s = VPNMatcher.parseList(listOutput.replacingOccurrences(of: "(Connected)    ", with: "(Disconnected) "))
    let t = VPNMatcher.tunnelState(services: s, serviceUUID: uuid, statusOutput: statusOutput)
    check(t?.status == .disconnected && t?.interface == nil && t?.isUp == false)
}

// MARK: State machine

let t0 = Date(timeIntervalSince1970: 1_000_000)
let user = Caller(isRoot: false)
let root = Caller(isRoot: true)
let up = TunnelState(status: .connected, interface: "ppp0")
let down = TunnelState(status: .disconnected, interface: nil)

test("state: off has no rules") {
    let m = StateMachine(config: makeConfig())
    check(try m.desired(tunnel: up, endpointIPs: ips, now: t0) == Desired(ruleset: nil))
}

test("state: refuses to arm without endpoints unless forced") {
    var m = StateMachine(config: makeConfig())
    throwsError(CommandError.noEndpoints) { try m.apply(.on(trialSeconds: nil, force: false), caller: user, endpointIPs: [], now: t0) }
    // --force without a trial is refused: a lockout must revert by itself.
    throwsError(CommandError.noEndpoints) { try m.apply(.on(trialSeconds: nil, force: true), caller: user, endpointIPs: [], now: t0) }
    try m.apply(.on(trialSeconds: 60, force: true), caller: user, endpointIPs: [], now: t0)
    check(m.mode == .on)
}

test("state: unconfirmed trial reverts, confirmed trial stays") {
    var m = StateMachine(config: makeConfig())
    try m.apply(.on(trialSeconds: 60, force: false), caller: user, endpointIPs: ips, now: t0)
    m.tick(now: t0.addingTimeInterval(61))
    check(m.mode == .off)
    try m.apply(.on(trialSeconds: 60, force: false), caller: user, endpointIPs: ips, now: t0)
    try m.apply(.confirm, caller: user, endpointIPs: ips, now: t0.addingTimeInterval(30))
    m.tick(now: t0.addingTimeInterval(120))
    check(m.mode == .on)
}

test("state: a trial cannot switch an armed, locked kill switch off") {
    var m = StateMachine(config: makeConfig(locked: true))
    try m.apply(.on(trialSeconds: nil, force: false), caller: user, endpointIPs: ips, now: t0)
    try m.apply(.on(trialSeconds: 10, force: false), caller: user, endpointIPs: ips, now: t0.addingTimeInterval(1))
    m.tick(now: t0.addingTimeInterval(100))
    check(m.mode == .on, "mode must stay on")
    check(m.trialDeadline == nil)
}

test("state: on while paused clears the pause but starts no trial") {
    var m = StateMachine(config: makeConfig(locked: false))
    try m.apply(.on(trialSeconds: nil, force: false), caller: user, endpointIPs: ips, now: t0)
    try m.apply(.pause(seconds: 300), caller: user, endpointIPs: ips, now: t0)
    try m.apply(.on(trialSeconds: 30, force: false), caller: user, endpointIPs: ips, now: t0)
    check(m.isEnforcing(now: t0))
    check(m.trialDeadline == nil)
}

test("state: locked off needs root") {
    var m = StateMachine(config: makeConfig(locked: true))
    try m.apply(.on(trialSeconds: nil, force: false), caller: user, endpointIPs: ips, now: t0)
    throwsError(CommandError.rootRequired) { try m.apply(.off, caller: user, endpointIPs: ips, now: t0) }
    try m.apply(.off, caller: root, endpointIPs: ips, now: t0)
    check(m.mode == .off)
}

test("state: unlocked off allowed for user") {
    var m = StateMachine(config: makeConfig(locked: false))
    try m.apply(.on(trialSeconds: nil, force: false), caller: user, endpointIPs: ips, now: t0)
    try m.apply(.off, caller: user, endpointIPs: ips, now: t0)
    check(m.mode == .off)
}

test("state: pause is capped and expires") {
    var m = StateMachine(config: makeConfig(locked: false))
    try m.apply(.on(trialSeconds: nil, force: false), caller: user, endpointIPs: ips, now: t0)
    throwsError(CommandError.pauseTooLong(max: 1800)) { try m.apply(.pause(seconds: 3600), caller: user, endpointIPs: ips, now: t0) }
    try m.apply(.pause(seconds: 300), caller: user, endpointIPs: ips, now: t0)
    check(!m.isEnforcing(now: t0.addingTimeInterval(10)))
    check(m.isEnforcing(now: t0.addingTimeInterval(301)))
}

test("state: plain on during a pending trial makes it permanent") {
    var m = StateMachine(config: makeConfig())
    try m.apply(.on(trialSeconds: 30, force: false), caller: user, endpointIPs: ips, now: t0)
    check(m.trialDeadline != nil)
    try m.apply(.on(trialSeconds: nil, force: false), caller: user, endpointIPs: ips, now: t0)
    check(m.trialDeadline == nil)
    m.tick(now: t0.addingTimeInterval(1000))
    check(m.mode == .on)
}

test("state: durations are range-checked, repeated pause is refused") {
    var m = StateMachine(config: makeConfig(locked: false))
    throwsError(CommandError.invalidDuration) { try m.apply(.on(trialSeconds: -5, force: false), caller: user, endpointIPs: ips, now: t0) }
    throwsError(CommandError.invalidDuration) { try m.apply(.on(trialSeconds: 99999, force: false), caller: user, endpointIPs: ips, now: t0) }
    try m.apply(.on(trialSeconds: nil, force: false), caller: user, endpointIPs: ips, now: t0)
    throwsError(CommandError.invalidDuration) { try m.apply(.pause(seconds: -10), caller: user, endpointIPs: ips, now: t0) }
    try m.apply(.pause(seconds: 60), caller: user, endpointIPs: ips, now: t0)
    throwsError(CommandError.alreadyPaused) { try m.apply(.pause(seconds: 60), caller: user, endpointIPs: ips, now: t0) }
    try m.apply(.resume, caller: user, endpointIPs: ips, now: t0)
    try m.apply(.pause(seconds: 60), caller: user, endpointIPs: ips, now: t0)
}

test("address: trailing newline and whitespace are rejected") {
    check(Address.isValid("1.2.3.4"))
    check(!Address.isValid("1.2.3.4\n"))
    check(!Address.isValid("1.2.3.4 "))
    check(!Address.isValidHostname("vpn.example.com\n"))
    check(!Address.isValidInterface("en0\n"))
    check(Address.isValidInterface("en0"))
}


// MARK: Daemon support

let netstatSample = """
Destination        Gateway            Flags               Netif Expire
default            link#27            UCSg                 ppp0
default            192.168.1.1        UGScIg                en0
192.168.1/24       link#14            UCS                   en0
192.168.1.1        1:2:3:4:5:6        UHLWIir               en0   1200
198.51.100.20      192.168.1.1        UGHS                  en0
224.0.0.251        1:0:5e:0:0:fb      UHmLWI                en0
239.255.255.250    1:0:5e:7f:ff:fa    UHmLWI                en0
10.20.30.40        192.168.1.1        UGHS                  en0
203.0.113.5        192.0.2.1     UGHS                 ppp0
"""

test("routes: finds the pinned VPN endpoint, ignores everything else") {
    check(RouteParser.endpointCandidates(netstat: netstatSample) == ["198.51.100.20"])
}

test("routes: public/private classification") {
    check(RouteParser.isPublicIPv4("198.51.100.20"))
    for p in ["10.1.2.3", "172.16.0.1", "172.31.255.1", "192.168.0.1", "169.254.1.1", "127.0.0.1", "224.0.0.1", "100.64.0.1"] {
        check(!RouteParser.isPublicIPv4(p), p)
    }
    check(RouteParser.isPublicIPv4("172.32.0.1"))
    check(!RouteParser.isIPv4("1.2.3"))
}

test("persisted state survives a round trip through the state machine") {
    var m = StateMachine(config: makeConfig())
    try m.apply(.on(trialSeconds: 60, force: false), caller: user, endpointIPs: ips, now: t0)
    let data = try JSONEncoder().encode(m.persisted)
    let back = try JSONDecoder().decode(PersistedState.self, from: data)
    let m2 = StateMachine(config: makeConfig(), persisted: back)
    check(m2.mode == .on)
    check(m2.trialDeadline == t0.addingTimeInterval(60))
}

test("ipc: request and response round trip, verbs map to commands") {
    let r = IPCRequest(verb: .on, trialSeconds: 60, force: true)
    let d = try JSONEncoder().encode(r)
    check(try JSONDecoder().decode(IPCRequest.self, from: d) == r)
    check(r.command == .on(trialSeconds: 60, force: true))
    check(IPCRequest(verb: .status).command == nil)
    check(IPCRequest(verb: .pause, seconds: 120).command == .pause(seconds: 120))
    check(throwsDecoding(IPCRequest.self, #"{"verb":"rm -rf"}"#))
}

func throwsDecoding<T: Decodable>(_ t: T.Type, _ json: String) -> Bool {
    (try? JSONDecoder().decode(t, from: Data(json.utf8))) == nil
}


// MARK: Client against fake daemons (short relative socket paths: sun_path is 104 bytes)

try? FileManager.default.createDirectory(atPath: ".kst", withIntermediateDirectories: true)
nonisolated(unsafe) var lastRequestLine = ""

/// Binds a socket at `path`. `listen == false` leaves a stale socket file behind.
func fakeDaemon(_ path: String, listen doListen: Bool = true, mode: UInt16 = 0o600, behavior: @escaping (Int32) -> Void) {
    unlink(path)
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    let bytes = Array(path.utf8CString)
    withUnsafeMutableBytes(of: &addr.sun_path) { raw in for (i, b) in bytes.enumerated() { raw[i] = UInt8(bitPattern: b) } }
    let len = socklen_t(MemoryLayout<sockaddr_un>.size)
    _ = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, len) } }
    chmod(path, mode_t(mode))
    if !doListen { close(fd); return }
    listen(fd, 4)
    Thread.detachNewThread {
        let c = accept(fd, nil, nil)
        if c >= 0 {
            var buf = [UInt8](repeating: 0, count: 4096)
            let n = read(c, &buf, buf.count)
            if n > 0 { lastRequestLine = String(decoding: buf[0..<n], as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) }
            behavior(c)
            close(c)
        }
        close(fd)
    }
}
func say(_ c: Int32, _ text: String) { let d = Array((text + "\n").utf8); _ = write(c, d, d.count) }

func clientError(_ path: String, timeout: TimeInterval = 1) -> ClientError? {
    do { _ = try DaemonClient(path: path, timeout: timeout).send(IPCRequest(verb: .status)); return nil }
    catch let e as ClientError { return e } catch { return .other("\(error)") }
}

test("client: valid answer, and the request reaches the daemon as a verb") {
    var ok = IPCResponse(ok: true); ok.mode = .on
    let reply = String(decoding: try JSONEncoder().encode(ok), as: UTF8.self)
    fakeDaemon(".kst/ok") { say($0, reply) }
    let r = try DaemonClient(path: ".kst/ok", timeout: 1).send(IPCRequest(verb: .on, trialSeconds: 60))
    check(r.ok && r.mode == .on)
    check(lastRequestLine.contains("\"verb\":\"on\""), lastRequestLine)
}

test("client: garbage answer is badResponse") {
    fakeDaemon(".kst/garbage") { say($0, "not json") }
    check(clientError(".kst/garbage") == .badResponse)
}

test("client: empty answer is badResponse") {
    fakeDaemon(".kst/empty") { _ in }
    check(clientError(".kst/empty") == .badResponse)
}

test("client: a daemon that never answers times out instead of hanging") {
    fakeDaemon(".kst/silent") { _ in sleep(3) }
    let start = Date()
    check(clientError(".kst/silent", timeout: 0.4) == .timeout)
    check(Date().timeIntervalSince(start) < 2, "returned too late")
}

test("client: stale socket file is refused") {
    fakeDaemon(".kst/stale", listen: false) { _ in }
    check(clientError(".kst/stale") == .refused)
}

test("client: missing socket is notInstalled") {
    unlink(".kst/missing")
    check(clientError(".kst/missing") == .notInstalled)
}

test("client: unreadable socket is permissionDenied") {
    fakeDaemon(".kst/locked", mode: 0o000) { _ in }
    check(clientError(".kst/locked") == .permissionDenied)
}

test("client: overlong path is an error, not a crash") {
    check(clientError(String(repeating: "a", count: 200)) == .other("socket path is too long"))
}


// MARK: UI logic (state, menu, privileged commands, recovery text)

func resp(mode: Mode = .on, enforcing: Bool = true, tunnel: String = "connected", iface: String? = "ppp0",
          rules: String = "up", pf: Bool = true, pause: Double? = nil, trial: Double? = nil) -> IPCResponse {
    var r = IPCResponse(ok: true)
    r.mode = mode; r.enforcing = enforcing; r.tunnel = tunnel; r.interface = iface
    r.rules = rules; r.pfEnabled = pf; r.pauseUntil = pause; r.trialDeadline = trial
    r.endpoints = ["203.0.113.10"]
    return r
}
let nowD = Date(timeIntervalSince1970: 2_000_000)
func kind(_ r: IPCResponse?, error: ClientError? = nil, age: TimeInterval? = 0, streak: Int = 0) -> UIKind {
    UIStateDeriver.derive(Snapshot(response: r, error: error, ageOfLastGood: age, inconsistentStreak: streak, now: nowD)).kind
}

test("ui: every state row") {
    check(kind(resp()) == .protected)
    check(kind(resp(tunnel: "disconnected", iface: nil, rules: "down")) == .blocked)
    check(kind(resp(tunnel: "connecting", iface: nil, rules: "down")) == .blocked)
    check(kind(resp(mode: .off, enforcing: false, rules: "none", pf: false)) == .off)
    check(kind(resp(enforcing: false, rules: "none", pause: nowD.timeIntervalSince1970 + 100)) == .paused)
    check(kind(nil, error: .refused) == .unreachable)
    check(kind(nil) == .unreachable)
}

test("ui: stale answer is unreachable, not protected") {
    check(kind(resp(), age: 7) == .unreachable)
    check(kind(resp(), age: 5) == .protected)
    check(kind(resp(), age: nil) == .unreachable)
}

test("ui: degraded needs two inconsistent polls (debounce)") {
    let bad = resp(rules: "none", pf: false)
    check(kind(bad, streak: 1) != .degraded)
    check(kind(bad, streak: 2) == .degraded)
    check(UIStateDeriver.looksInconsistent(resp(tunnel: "connected", rules: "down")))
    check(UIStateDeriver.looksInconsistent(resp(tunnel: "disconnected", iface: nil, rules: "up")))
    check(!UIStateDeriver.looksInconsistent(resp()))
    check(!UIStateDeriver.looksInconsistent(resp(mode: .off, enforcing: false, rules: "none")))
}

test("ui: trial overlays any state and puts the countdown in the title") {
    let s = UIStateDeriver.derive(Snapshot(response: resp(trial: nowD.timeIntervalSince1970 + 42), now: nowD))
    check(s.kind == .protected && s.trialSecondsLeft == 42 && s.title == "42s")
    check(s.accessibilityLabel.contains("trial"))
}

test("ui: countdown format") {
    check(Countdown.format(42) == "42s")
    check(Countdown.format(59) == "59s")
    check(Countdown.format(60) == "1:00")
    check(Countdown.format(125) == "2:05")
    check(Countdown.format(-3) == "0s")
}

func plan(_ r: IPCResponse?, error: ClientError? = nil, locked: Bool = true, maxPause: Int = 1800, streak: Int = 0) -> [MenuEntry] {
    let st = UIStateDeriver.derive(Snapshot(response: r, error: error, ageOfLastGood: r == nil ? nil : 0, inconsistentStreak: streak, now: nowD))
    return MenuPlan.make(state: st, config: ConfigView(locked: locked, maxPauseSeconds: maxPause))
}
func has(_ p: [MenuEntry], _ a: MenuAction) -> MenuEntry? { p.first { $0.action == a } }

test("menu: protected offers Turn Off and Pause (both need admin when locked), no Connect") {
    let p = plan(resp())
    check(has(p, .turnOff)?.needsAdmin == true)
    check(has(p, .pause)?.needsAdmin == true)
    check(has(p, .connectVPN) == nil && has(p, .emergency) == nil && has(p, .turnOn) == nil)
}

test("menu: unlocked config needs no admin") {
    let p = plan(resp(), locked: false)
    check(has(p, .turnOff)?.needsAdmin == false && has(p, .pause)?.needsAdmin == false)
}

test("menu: pause hidden when the cap is below 5 minutes") {
    check(has(plan(resp(), maxPause: 120), .pause) == nil)
    check(has(plan(resp(), maxPause: 300), .pause) != nil)
}

test("menu: blocked shows Connect VPN") {
    check(has(plan(resp(tunnel: "disconnected", iface: nil, rules: "down")), .connectVPN) != nil)
}

test("menu: off shows Turn On (no trial), no Turn Off") {
    let p = plan(resp(mode: .off, enforcing: false, rules: "none"))
    check(has(p, .turnOn)?.enabled == true && has(p, .turnOff) == nil && has(p, .pause) == nil)
}

test("menu: paused shows Resume and no second Pause") {
    let p = plan(resp(enforcing: false, rules: "none", pause: nowD.timeIntervalSince1970 + 100))
    check(has(p, .resume) != nil && has(p, .pause) == nil)
}

test("menu: unreachable and degraded offer Emergency release; healthy states do not") {
    check(has(plan(nil, error: .timeout), .emergency)?.needsAdmin == true)
    check(has(plan(resp(rules: "none", pf: false), streak: 2), .emergency) != nil)
    check(has(plan(resp()), .emergency) == nil)
    check(has(plan(nil, error: .timeout), .turnOn)?.enabled == false)
}

test("menu: trial adds banner, Keep and Revert now") {
    let p = plan(resp(trial: nowD.timeIntervalSince1970 + 30))
    check(has(p, .trialBanner) != nil && has(p, .keep) != nil && has(p, .revertNow)?.needsAdmin == true)
    check(has(plan(resp()), .trialBanner) == nil)
}

test("menu: Quit and recovery are always present") {
    for r in [resp(), resp(mode: .off, enforcing: false, rules: "none")] {
        check(has(plan(r), .quit) != nil && has(plan(r), .recovery) != nil)
    }
    check(has(plan(nil, error: .refused), .quit) != nil)
}

test("privileged: commands are constants, pause is a validated integer") {
    check(try PrivilegedCommand.shellCommand(for: .off, maxPause: 1800) == "/usr/local/bin/ksctl off")
    check(try PrivilegedCommand.shellCommand(for: .pause(seconds: 300), maxPause: 1800) == "/usr/local/bin/ksctl pause 300")
    throwsError(PrivilegedError.badPause) { _ = try PrivilegedCommand.shellCommand(for: .pause(seconds: 3600), maxPause: 1800) }
    throwsError(PrivilegedError.badPause) { _ = try PrivilegedCommand.shellCommand(for: .pause(seconds: 0), maxPause: 1800) }
    throwsError(PrivilegedError.badPause) { _ = try PrivilegedCommand.shellCommand(for: .pause(seconds: -5), maxPause: 1800) }
    let e = try PrivilegedCommand.shellCommand(for: .emergencyRelease, maxPause: 1800)
    check(e.hasPrefix("/bin/launchctl bootout system/") && e.hasSuffix("panic.sh"))
}

test("privileged: AppleScript has no stray quotes and asks for administrator privileges") {
    let a = try PrivilegedCommand.appleScript(for: .off, maxPause: 1800)
    check(a == "do shell script \"/usr/local/bin/ksctl off\" with prompt \"VPN Kill Switch wants to turn protection off.\" with administrator privileges", a)
    for act in [PrivilegedAction.off, .pause(seconds: 300), .emergencyRelease] {
        let s = try PrivilegedCommand.appleScript(for: act, maxPause: 1800)
        check(s.filter { $0 == "\"" }.count == 4, s)
    }
}

test("privileged: path safety needs root ownership all the way up, no group/other write") {
    let ok: (String) -> (uid: UInt32, mode: UInt16)? = { _ in (0, 0o755) }
    check(PrivilegedCommand.pathIsSafe("/usr/local/bin/ksctl", stat: ok))
    let userOwned: (String) -> (uid: UInt32, mode: UInt16)? = { $0 == "/usr/local" ? (501, 0o755) : (0, 0o755) }
    check(!PrivilegedCommand.pathIsSafe("/usr/local/bin/ksctl", stat: userOwned))
    let writable: (String) -> (uid: UInt32, mode: UInt16)? = { $0 == "/usr/local/bin" ? (0, 0o775) : (0, 0o755) }
    check(!PrivilegedCommand.pathIsSafe("/usr/local/bin/ksctl", stat: writable))
    check(!PrivilegedCommand.pathIsSafe("/nope", stat: { _ in nil }))
}

test("recovery: every command in the app also appears in docs/RECOVERY.md") {
    guard let doc = try? String(contentsOfFile: "docs/RECOVERY.md", encoding: .utf8) else {
        check(false, "run from the repository root"); return
    }
    for step in RecoveryText.steps {
        let bare = step.command.hasPrefix("sudo ") ? String(step.command.dropFirst(5)) : step.command
        check(doc.contains(bare), "missing in docs/RECOVERY.md: \(bare)")
    }
}


// MARK: actions and notifications

test("actions: Turn On is a permanent on (no trial)") {
    let p = ActionMapper.plan(for: .turnOn, config: ConfigView(locked: true, maxPauseSeconds: 1800))
    check(p == .daemon(IPCRequest(verb: .on)))
    if case let .daemon(r) = p { check(r.trialSeconds == nil && r.command == .on(trialSeconds: nil, force: false)) }
}

test("actions: locked config sends off and pause through the password prompt") {
    let locked = ConfigView(locked: true, maxPauseSeconds: 1800)
    check(ActionMapper.plan(for: .turnOff, config: locked) == .privileged(.off))
    check(ActionMapper.plan(for: .revertNow, config: locked) == .privileged(.off))
    check(ActionMapper.plan(for: .pause, config: locked) == .privileged(.pause(seconds: 300)))
    check(ActionMapper.plan(for: .emergency, config: locked) == .privileged(.emergencyRelease))
}

test("actions: unlocked config talks to the daemon directly; Keep and Resume never need a password") {
    let open = ConfigView(locked: false, maxPauseSeconds: 1800)
    check(ActionMapper.plan(for: .turnOff, config: open) == .daemon(IPCRequest(verb: .off)))
    check(ActionMapper.plan(for: .pause, config: open) == .daemon(IPCRequest(verb: .pause, seconds: 300)))
    for locked in [true, false] {
        let c = ConfigView(locked: locked, maxPauseSeconds: 1800)
        check(ActionMapper.plan(for: .keep, config: c) == .daemon(IPCRequest(verb: .confirm)))
        check(ActionMapper.plan(for: .resume, config: c) == .daemon(IPCRequest(verb: .resume)))
        check(ActionMapper.plan(for: .quit, config: c) == .none)
        check(ActionMapper.plan(for: .details, config: c) == .none)
    }
}

func uiState(_ r: IPCResponse?, error: ClientError? = nil, streak: Int = 0) -> UIState {
    UIStateDeriver.derive(Snapshot(response: r, error: error, ageOfLastGood: r == nil ? nil : 0, inconsistentStreak: streak, now: nowD))
}
let blockedR = resp(tunnel: "disconnected", iface: nil, rules: "down")
let offR = resp(mode: .off, enforcing: false, rules: "none")

test("notify: nothing for the first state, nothing when nothing changes") {
    check(NotificationPlanner.events(from: nil, to: uiState(resp())).isEmpty)
    check(NotificationPlanner.events(from: uiState(resp()), to: uiState(resp())).isEmpty)
}

test("notify: VPN drop and reconnect") {
    let drop = NotificationPlanner.events(from: uiState(resp()), to: uiState(blockedR))
    check(drop.count == 1 && drop[0].title.contains("VPN is down"))
    let back = NotificationPlanner.events(from: uiState(blockedR), to: uiState(resp()))
    check(back.count == 1 && back[0].title == "VPN connected" && back[0].body.contains("ppp0"))
}

test("notify: trial start, and revert to off") {
    let started = NotificationPlanner.events(from: uiState(offR), to: uiState(resp(trial: nowD.timeIntervalSince1970 + 60)))
    check(started.count == 1 && started[0].title.contains("trial started"))
    let ended = NotificationPlanner.events(from: uiState(resp(trial: nowD.timeIntervalSince1970 + 1)), to: uiState(offR))
    check(ended.count == 1 && ended[0].title == "Trial ended")
}

test("notify: degraded, unreachable, manual off, pause end") {
    check(NotificationPlanner.events(from: uiState(resp()), to: uiState(resp(rules: "none", pf: false), streak: 2))[0].title.contains("attention"))
    check(NotificationPlanner.events(from: uiState(resp()), to: uiState(nil, error: .timeout))[0].title.contains("not reachable"))
    check(NotificationPlanner.events(from: uiState(resp()), to: uiState(offR))[0].title == "Kill switch turned off")
    let paused = uiState(resp(enforcing: false, rules: "none", pause: nowD.timeIntervalSince1970 + 100))
    check(NotificationPlanner.events(from: paused, to: uiState(resp()))[0].title == "Pause ended")
}

test("notify: a daemon that comes back is quiet; going off from unreachable is not 'turned off'") {
    check(NotificationPlanner.events(from: uiState(nil, error: .timeout), to: uiState(resp())).isEmpty)
    check(NotificationPlanner.events(from: uiState(nil, error: .timeout), to: uiState(offR)).isEmpty)
}

// MARK: Daemon with fake pf

final class FakePF: PFControlling {
    var enabled = false
    var enableCalls = 0
    var loads: [String] = []
    var flushes = 0
    var anchor = false
    var failNormalLoads = false     // reject any ruleset that is not the emergency set
    var main = "scrub-anchor \"com.apple/*\"\nanchor \"com.apple/*\" all\n"
    func mainRules() -> String { main }
    func isEnabled() -> Bool { enabled }
    func enable() -> String? { enableCalls += 1; enabled = true; return "tok\(enableCalls)" }
    func release(token: String) { enabled = false }
    func load(anchor a: String, rules: String) -> Bool {
        if failNormalLoads && !rules.contains("# emergency set") { return false }
        loads.append(rules); anchor = true; return true
    }
    func flush(anchor a: String) { flushes += 1; anchor = false }
    func anchorHasRules(anchor a: String) -> Bool { anchor }
}

final class FakeProbe: SystemProbe {
    var state: TunnelState?
    var calls = 0
    init(_ s: TunnelState?) { state = s }
    func tunnel(config: Config) -> TunnelState? { calls += 1; return state }
    func routes() -> String { "" }
}

func tempDir() -> String {
    let d = NSTemporaryDirectory() + "ks-test-" + UUID().uuidString
    try? FileManager.default.createDirectory(atPath: d, withIntermediateDirectories: true)
    return d
}

func makeDaemon(mode: Mode, pf: FakePF, probe: FakeProbe, dir: String, token: String? = nil) -> Daemon {
    if let token { try? token.write(toFile: dir + "/token", atomically: true, encoding: .utf8) }
    var persisted = PersistedState()
    persisted.mode = mode
    let paths = Paths(stateFile: dir + "/state.json", endpointsFile: dir + "/endpoints.json",
                      tokenFile: dir + "/token", socket: dir + "/sock")
    return Daemon(config: makeConfig(), persisted: persisted, endpoints: ips, pf: pf, paths: paths, probe: probe)
}

test("daemon: a pf token saved before a restart is reused, not re-taken") {
    let dir = tempDir(); defer { try? FileManager.default.removeItem(atPath: dir) }
    let pf = FakePF(); pf.enabled = true
    let d = makeDaemon(mode: .on, pf: pf, probe: FakeProbe(up), dir: dir, token: "777")
    check(d.token == "777")
    d.start()
    check(pf.enableCalls == 0, "enable() called \(pf.enableCalls) times")
}

test("daemon: enforcing start loads the down set before probing, then the up set") {
    let dir = tempDir(); defer { try? FileManager.default.removeItem(atPath: dir) }
    let pf = FakePF()
    let d = makeDaemon(mode: .on, pf: pf, probe: FakeProbe(up), dir: dir)
    d.start()
    check(pf.loads.count == 2, "loads: \(pf.loads.count)")
    check(pf.loads.first.map { !$0.contains("on ppp0") } ?? false, "first load must be the down set")
    check(pf.loads.last?.contains("on ppp0") ?? false, "second load must be the up set")
    check(pf.flushes == 0, "must not flush an enforcing start")
}

test("daemon: start with the kill switch off flushes and loads nothing") {
    let dir = tempDir(); defer { try? FileManager.default.removeItem(atPath: dir) }
    let pf = FakePF()
    let d = makeDaemon(mode: .off, pf: pf, probe: FakeProbe(up), dir: dir)
    d.start()
    check(pf.flushes >= 1 && pf.loads.isEmpty)
}

test("daemon: a second reconcile does not take another pf reference") {
    let dir = tempDir(); defer { try? FileManager.default.removeItem(atPath: dir) }
    let pf = FakePF()
    let d = makeDaemon(mode: .on, pf: pf, probe: FakeProbe(up), dir: dir)
    d.start(); d.reconcile("tick"); d.reconcile("tick")
    check(pf.enableCalls == 1, "enable() called \(pf.enableCalls) times")
}

test("main ruleset check: stock pf.conf is clean") {
    check(PFMainRuleset.check("scrub-anchor \"com.apple/*\" all fragment reassemble\nanchor \"com.apple/*\" all\n").isEmpty)
}
test("main ruleset check: missing anchor and foreign quick pass are reported") {
    check(PFMainRuleset.check("").count == 1)
    check(PFMainRuleset.check("block drop all\n").count == 1)
    let r = PFMainRuleset.check("pass quick on utun3 all flags S/SA keep state\nanchor \"com.apple/*\" all\n")
    check(r.count == 1 && r[0].contains("precedes"))
    // a quick pass AFTER the anchor does not matter
    check(PFMainRuleset.check("anchor \"com.apple/*\" all\npass quick on lo0 all\n").isEmpty)
}
test("state loading: missing file is off; corrupt is on when locked, off otherwise") {
    check(StateLoading.load(data: nil, locked: true).state.mode == .off)
    let bad = Data("{not json".utf8)
    let l = StateLoading.load(data: bad, locked: true)
    check(l.state.mode == .on && l.note != nil)
    check(StateLoading.load(data: bad, locked: false).state.mode == .off)
    check(StateLoading.load(data: Data(), locked: true).state.mode == .on)
    let good = try JSONEncoder().encode(PersistedState(mode: .on))
    check(StateLoading.load(data: good, locked: true).note == nil)
}
test("emergency ruleset: quick passes before the final block, no DNS/LAN/exempt, bad input dropped") {
    let c = makeConfig(exempt: ["198.51.100.7"], lan: true)
    let r = RulesetBuilder.emergency(config: c, tunnelInterface: "ppp0", endpointIPs: ["203.0.113.10", "1.2.3.4\n", "x y"], tunnelUp: true)
    let lines = r.text.split(separator: "\n").filter { !$0.hasPrefix("#") && !$0.hasPrefix("table") }
    check(lines.last == "block return out quick log all")
    check(lines.allSatisfy { $0.contains("quick") })
    check(!r.text.contains("ks_dns") && !r.text.contains("pass out quick to {") && !r.text.contains("198.51.100.7"))
    check(r.text.contains("table <ks_endpoints> persist { 203.0.113.10 }"))
    check(r.text.contains("on ppp0"))
}
test("daemon: if the normal ruleset fails to load and nothing is loaded, the emergency set is") {
    let dir = tempDir(); defer { try? FileManager.default.removeItem(atPath: dir) }
    let pf = FakePF(); pf.failNormalLoads = true
    let d = makeDaemon(mode: .on, pf: pf, probe: FakeProbe(up), dir: dir)
    d.start()
    check(pf.loads.count >= 1 && pf.loads.allSatisfy { $0.contains("# emergency set") })
    check(d.statusResponse().rules == "emergency")
    pf.failNormalLoads = false
    d.reconcile("retry")
    check(d.statusResponse().rules == "up", "normal set must be retried and win")
}
test("daemon: a tampered main ruleset is reported as a problem") {
    let dir = tempDir(); defer { try? FileManager.default.removeItem(atPath: dir) }
    let pf = FakePF()
    let d = makeDaemon(mode: .on, pf: pf, probe: FakeProbe(up), dir: dir)
    d.start()
    check(d.statusResponse().problems == nil)
    pf.main = "block drop all\n"
    d.cheapCheck()
    check(d.statusResponse().problems?.count == 1)
    var r = d.statusResponse(); r.rules = "up"; r.tunnel = "connected"
    check(UIStateDeriver.looksInconsistent(r))
}
test("daemon: cheapCheck repairs a disabled pf and an emptied anchor") {
    let dir = tempDir(); defer { try? FileManager.default.removeItem(atPath: dir) }
    let pf = FakePF()
    let d = makeDaemon(mode: .on, pf: pf, probe: FakeProbe(up), dir: dir)
    d.start()
    let before = pf.loads.count
    pf.enabled = false; pf.anchor = false
    d.cheapCheck()
    check(pf.enabled && pf.anchor && pf.loads.count == before + 1)
}

test("ruleset: DHCP only to broadcast, private ranges and configured servers") {
    let r = try RulesetBuilder.build(config: makeConfig(), tunnelInterface: "ppp0", endpointIPs: ips, tunnelUp: true)
    check(!r.text.contains("to any port 67"))
    let dhcp = r.text.split(separator: "\n").first { $0.contains("port 67") }.map(String.init) ?? ""
    check(dhcp.contains("255.255.255.255") && dhcp.contains("192.168.0.0/16") && !dhcp.contains("203.0.113"))
    var c = makeConfig(); c.dhcpServers = ["198.51.100.1"]
    let r2 = try RulesetBuilder.build(config: c, tunnelInterface: nil, endpointIPs: ips, tunnelUp: false)
    check(r2.text.contains("198.51.100.1"))
    c.dhcpServers = ["1.2.3.4\n"]
    check(!c.validate().isEmpty)
    throwsAny { _ = try RulesetBuilder.build(config: c, tunnelInterface: nil, endpointIPs: ips, tunnelUp: false) }
    check(RulesetBuilder.emergency(config: makeConfig(), tunnelInterface: nil, endpointIPs: ips, tunnelUp: false).text.contains("to { 255.255.255.255"))
}

print("\n\(checks) checks, \(failures) failures")
exit(failures == 0 ? 0 : 1)

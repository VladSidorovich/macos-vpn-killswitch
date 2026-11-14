import Foundation
import KillSwitchCore

/// Everything the daemon asks of the machine besides pf. Tests substitute a fake.
package protocol SystemProbe: AnyObject {
    func tunnel(config: Config) -> TunnelState?
    func routes() -> String
}

package final class RealProbe: SystemProbe {
    package init() {}
    package func tunnel(config: Config) -> TunnelState? {
        let list = shell("/usr/sbin/scutil", ["--nc", "list"])
        guard list.status == 0 else { log("scutil --nc list failed; treating tunnel as down"); return nil }
        let services = VPNMatcher.parseList(list.out)
        guard let svc = services.first(where: { $0.uuid == config.serviceUUID.uppercased() }) else { return nil }
        var statusOut: String?
        if svc.status == .connected {
            statusOut = shell("/usr/sbin/scutil", ["--nc", "status", config.serviceUUID]).out
        }
        return VPNMatcher.tunnelState(services: services, serviceUUID: config.serviceUUID, statusOutput: statusOut)
    }
    package func routes() -> String { shell("/usr/sbin/netstat", ["-rn", "-f", "inet"]).out }
}

package struct Paths {
    package var stateFile: String
    package var endpointsFile: String
    package var tokenFile: String
    package var socket: String
    package init(stateFile: String, endpointsFile: String, tokenFile: String, socket: String) {
        self.stateFile = stateFile; self.endpointsFile = endpointsFile
        self.tokenFile = tokenFile; self.socket = socket
    }
}

/// Owns the state machine and applies the desired ruleset to pf.
/// Everything runs on the main queue; there is no locking.
package final class Daemon {
    let config: Config
    let pf: PFControlling
    let probe: SystemProbe
    let paths: Paths
    package var machine: StateMachine
    var endpoints: [String]
    var tunnel: TunnelState?
    var lastLoaded: String?
    var lastRulesKind = "none"
    package var problems: [String] = []
    package var token: String?
    private var lastEnforcing = false

    package init(config: Config, persisted: PersistedState, endpoints: [String], pf: PFControlling,
                 paths: Paths, probe: SystemProbe = RealProbe()) {
        self.config = config
        self.probe = probe
        self.machine = StateMachine(config: config, persisted: persisted)
        self.endpoints = endpoints
        self.pf = pf
        self.paths = paths
        // Reuse the pf reference taken before a restart instead of leaking a new one each time.
        if let t = try? String(contentsOfFile: paths.tokenFile, encoding: .utf8) {
            let t = t.trimmingCharacters(in: .whitespacesAndNewlines)
            if !t.isEmpty { token = t }
        }
    }

    // MARK: probing

    func probeTunnel() -> TunnelState? { probe.tunnel(config: config) }

    /// While the tunnel is up, learn the real endpoint from the pinned host route.
    func refreshEndpoints() {
        let routes = probe.routes()
        var learned = RouteParser.endpointCandidates(netstat: routes)
        learned += config.servers.filter { RouteParser.isIPv4($0) }
        learned = Array(Set(learned)).sorted()
        if !learned.isEmpty && learned != endpoints {
            log("endpoints: \(endpoints) -> \(learned)")
            endpoints = learned
            writeJSON(endpoints, to: paths.endpointsFile)
        }
    }

    // MARK: reconcile

    package func reconcile(_ reason: String) {
        machine.tick(now: Date())
        tunnel = probeTunnel()
        if tunnel?.isUp == true { refreshEndpoints() }
        persist()
        apply(reason)
        refreshProblems()
    }

    func apply(_ reason: String) {
        let now = Date()
        lastEnforcing = machine.isEnforcing(now: now)
        let desired: Desired
        do { desired = try machine.desired(tunnel: tunnel, endpointIPs: endpoints, now: now) }
        catch {
            log("cannot build ruleset (\(error)); keeping what is loaded")
            if lastEnforcing { loadEmergencyIfNothingLoaded(reason) }
            return
        }

        if let rules = desired.ruleset {
            let kind = (tunnel?.isUp ?? false) ? "up" : "down"
            let wasEnabled = pf.isEnabled()
            if !wasEnabled || token == nil {
                if let t = pf.enable() {
                    token = t; writeToken(t)
                    if !wasEnabled && lastLoaded != nil { log("pf was disabled; re-enabled (\(reason))") }
                } else { log("could not enable pf") }
            }
            if rules.text != lastLoaded || !pf.anchorHasRules(anchor: RulesetBuilder.anchor) {
                if pf.load(anchor: RulesetBuilder.anchor, rules: rules.text) {
                    lastLoaded = rules.text
                    log("rules loaded: \(kind) set (\(reason))")
                    lastRulesKind = kind
                } else {
                    // Keep whatever is loaded (fail-closed); if nothing is, use the emergency set.
                    loadEmergencyIfNothingLoaded(reason)
                }
            } else {
                lastRulesKind = kind
            }
        } else if lastLoaded != nil || token != nil {
            pf.flush(anchor: RulesetBuilder.anchor)
            if let t = token { pf.release(token: t) }
            token = nil
            lastLoaded = nil
            lastRulesKind = "none"
            try? FileManager.default.removeItem(atPath: paths.tokenFile)
            log("rules removed (\(reason))")
        }
    }

    private func loadEmergencyIfNothingLoaded(_ reason: String) {
        guard !pf.anchorHasRules(anchor: RulesetBuilder.anchor) else { return }
        let e = RulesetBuilder.emergency(config: config, tunnelInterface: tunnel?.interface,
                                         endpointIPs: endpoints, tunnelUp: tunnel?.isUp ?? false)
        if !pf.isEnabled(), let t = pf.enable() { token = t; writeToken(t) }
        if pf.load(anchor: RulesetBuilder.anchor, rules: e.text) {
            lastLoaded = nil            // so the next reconcile retries the normal set
            lastRulesKind = "emergency"
            log("EMERGENCY rules loaded (\(reason)): the normal ruleset failed")
        } else {
            log("emergency rules failed to load too")
        }
    }

    /// Reports (never repairs) a main ruleset that no longer evaluates our anchor.
    func refreshProblems() {
        problems = machine.isEnforcing(now: Date()) ? PFMainRuleset.check(pf.mainRules()) : []
    }

    /// Cheap check every few seconds: repair pf drift quickly, refresh the tamper report.
    package func cheapCheck() {
        guard machine.isEnforcing(now: Date()) else { problems = []; return }
        if !pf.isEnabled() || !pf.anchorHasRules(anchor: RulesetBuilder.anchor) { reconcile("integrity check") }
        else { refreshProblems() }
    }

    /// Cheap check run every second: only reconcile when enforcement flipped (pause/trial expiry).
    package func quickTick() {
        let before = machine.isEnforcing(now: Date())
        machine.tick(now: Date())
        let after = machine.isEnforcing(now: Date())
        if before != after || after != lastEnforcing { reconcile("timer") }
    }

    /// Start-up: drop stale rules if we are not supposed to enforce. When enforcing, load the
    /// "tunnel down" set from cached endpoints first, so nothing leaks while probing.
    package func start() {
        if machine.isEnforcing(now: Date()) {
            tunnel = nil
            apply("start, before probing")
        } else {
            pf.flush(anchor: RulesetBuilder.anchor)
        }
        reconcile("start")
    }

    // MARK: commands

    package func handle(_ req: IPCRequest, peerIsRoot: Bool) -> IPCResponse {
        if let cmd = req.command {
            tunnel = probeTunnel()
            if tunnel?.isUp == true { refreshEndpoints() }
            do { try machine.apply(cmd, caller: Caller(isRoot: peerIsRoot), endpointIPs: endpoints, now: Date()) }
            catch let e as CommandError { return IPCResponse(ok: false, error: e.message) }
            catch { return IPCResponse(ok: false, error: "\(error)") }
            persist()
            apply("command \(req.verb.rawValue)")
        }
        return statusResponse()
    }

    package func statusResponse() -> IPCResponse {
        var r = IPCResponse(ok: true)
        r.mode = machine.mode
        r.enforcing = machine.isEnforcing(now: Date())
        r.tunnel = tunnel?.status.rawValue.lowercased() ?? "unknown"
        r.interface = tunnel?.interface
        r.endpoints = endpoints
        r.pauseUntil = machine.pauseUntil?.timeIntervalSince1970
        r.trialDeadline = machine.trialDeadline?.timeIntervalSince1970
        r.rules = lastRulesKind
        r.pfEnabled = pf.isEnabled()
        r.problems = problems.isEmpty ? nil : problems
        return r
    }

    // MARK: persistence

    func persist() { writeJSON(machine.persisted, to: paths.stateFile) }

    private func writeToken(_ t: String) {
        try? t.write(toFile: paths.tokenFile, atomically: true, encoding: .utf8)
    }
}

package func writeJSON<T: Encodable>(_ value: T, to path: String) {
    do {
        let data = try JSONEncoder().encode(value)
        try data.write(to: URL(fileURLWithPath: path), options: .atomic)
    } catch { log("cannot write \(path): \(error)") }
}

package func readJSON<T: Decodable>(_ type: T.Type, from path: String) -> T? {
    guard let d = FileManager.default.contents(atPath: path) else { return nil }
    return try? JSONDecoder().decode(type, from: d)
}

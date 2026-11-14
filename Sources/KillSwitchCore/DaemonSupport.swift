import Foundation

// MARK: Persisted state

public struct PersistedState: Codable, Equatable, Sendable {
    public var mode: Mode
    public var pauseUntil: Double?       // seconds since 1970
    public var trialDeadline: Double?
    public init(mode: Mode = .off, pauseUntil: Double? = nil, trialDeadline: Double? = nil) {
        self.mode = mode
        self.pauseUntil = pauseUntil
        self.trialDeadline = trialDeadline
    }
}

extension StateMachine {
    public init(config: Config, persisted: PersistedState) {
        self.init(config: config, mode: persisted.mode)
        self.pauseUntil = persisted.pauseUntil.map { Date(timeIntervalSince1970: $0) }
        self.trialDeadline = persisted.trialDeadline.map { Date(timeIntervalSince1970: $0) }
    }

    public var persisted: PersistedState {
        PersistedState(mode: mode,
                       pauseUntil: pauseUntil?.timeIntervalSince1970,
                       trialDeadline: trialDeadline?.timeIntervalSince1970)
    }
}

// MARK: Socket protocol (one JSON object per line)

public enum Verb: String, Codable, Sendable {
    case status, on, confirm, off, pause, resume
}

public struct IPCRequest: Codable, Equatable, Sendable {
    public var verb: Verb
    public var trialSeconds: Int?
    public var force: Bool?
    public var seconds: Int?
    public init(verb: Verb, trialSeconds: Int? = nil, force: Bool? = nil, seconds: Int? = nil) {
        self.verb = verb
        self.trialSeconds = trialSeconds
        self.force = force
        self.seconds = seconds
    }

    /// Verbs map to state-machine commands; `status` has none.
    public var command: Command? {
        switch verb {
        case .status: return nil
        case .on: return .on(trialSeconds: trialSeconds, force: force ?? false)
        case .confirm: return .confirm
        case .off: return .off
        case .pause: return .pause(seconds: seconds ?? 300)
        case .resume: return .resume
        }
    }
}

public struct IPCResponse: Codable, Equatable, Sendable {
    public var ok: Bool
    public var error: String?
    public var mode: Mode?
    public var enforcing: Bool?
    public var tunnel: String?          // connected / connecting / disconnected / unknown
    public var interface: String?
    public var endpoints: [String]?
    public var pauseUntil: Double?
    public var trialDeadline: Double?
    public var rules: String?           // "up" / "down" / "none"
    public var pfEnabled: Bool?
    public var problems: [String]?      // pf tampering / degraded conditions; older clients ignore it
    public init(ok: Bool, error: String? = nil) { self.ok = ok; self.error = error }
}

extension CommandError {
    public var message: String {
        switch self {
        case .rootRequired: return "root required (the config is locked); use sudo"
        case .noEndpoints: return "no VPN endpoint address known yet; connect the VPN once, or use --force"
        case let .pauseTooLong(max): return "pause is capped at \(max) seconds"
        case .notInTrial: return "no trial is running"
        case .notArmed: return "kill switch is not on"
        case .alreadyPaused: return "already paused; resume first"
        case .invalidDuration: return "duration out of range"
        }
    }
}

// MARK: Endpoint learning from the routing table

/// The VPN client pins a host route to the server via the physical gateway so tunnel
/// traffic does not loop. While the tunnel is up that route reveals the real endpoint,
/// which can differ from what the (VPN-supplied) DNS answers.
public enum RouteParser {
    /// Input: `netstat -rn -f inet`. Columns: Destination Gateway Flags Netif [Expire].
    public static func endpointCandidates(netstat: String) -> [String] {
        var found = Set<String>()
        for line in netstat.split(separator: "\n") {
            let f = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            guard f.count >= 4 else { continue }
            let (dest, gw, flags, iface) = (f[0], f[1], f[2], f[3])
            guard isIPv4(dest), isIPv4(gw), iface.hasPrefix("en") else { continue }
            guard flags.contains("H"), flags.contains("G"), flags.contains("S") else { continue }
            guard isPublicIPv4(dest) else { continue }
            found.insert(dest)
        }
        return found.sorted()
    }

    static func octets(_ s: String) -> [Int]? {
        let p = s.split(separator: ".", omittingEmptySubsequences: false)
        guard p.count == 4 else { return nil }
        let n = p.compactMap { Int($0) }
        return n.count == 4 && n.allSatisfy({ (0...255).contains($0) }) ? n : nil
    }

    public static func isIPv4(_ s: String) -> Bool { octets(s) != nil }

    public static func isPublicIPv4(_ s: String) -> Bool {
        guard let o = octets(s) else { return false }
        switch (o[0], o[1]) {
        case (0, _), (10, _), (127, _), (169, 254), (192, 168): return false
        case (172, 16...31): return false
        case (100, 64...127): return false
        case (224...255, _): return false
        default: return true
        }
    }
}

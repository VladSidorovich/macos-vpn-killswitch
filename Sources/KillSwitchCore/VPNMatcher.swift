import Foundation

public enum ServiceStatus: String, Equatable, Sendable {
    case connected = "Connected"
    case connecting = "Connecting"
    case disconnecting = "Disconnecting"
    case disconnected = "Disconnected"
    case invalid = "Invalid"
}

public struct ServiceSnapshot: Equatable, Sendable {
    public let uuid: String
    public let name: String
    public let status: ServiceStatus
    public init(uuid: String, name: String, status: ServiceStatus) {
        self.uuid = uuid
        self.name = name
        self.status = status
    }
}

public struct TunnelState: Equatable, Sendable {
    public let status: ServiceStatus
    /// Interface name (e.g. ppp0). Only meaningful while connected.
    public let interface: String?
    public init(status: ServiceStatus, interface: String?) { self.status = status; self.interface = interface }
    public var isUp: Bool { status == .connected && interface != nil }
}

/// Parsers and matching over `scutil --nc` output. No process spawning here.
public enum VPNMatcher {
    private static let line = try! NSRegularExpression(
        pattern: #"\((Connected|Connecting|Disconnecting|Disconnected|Invalid)\)\s+([0-9A-Fa-f-]{36})\s+.*?"([^"]+)""#)
    private static let ifaceLine = try! NSRegularExpression(pattern: #"InterfaceName\s*:\s*(\S+)"#)

    /// Parse `scutil --nc list`.
    public static func parseList(_ output: String) -> [ServiceSnapshot] {
        output.split(separator: "\n").compactMap { raw in
            let s = String(raw)
            guard let m = line.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)),
                  let st = Range(m.range(at: 1), in: s), let u = Range(m.range(at: 2), in: s),
                  let n = Range(m.range(at: 3), in: s),
                  let status = ServiceStatus(rawValue: String(s[st]))
            else { return nil }
            return ServiceSnapshot(uuid: String(s[u]).uppercased(), name: String(s[n]), status: status)
        }
    }

    /// Parse the interface out of `scutil --nc status <service>` output.
    public static func parseInterface(_ statusOutput: String) -> String? {
        guard let m = ifaceLine.firstMatch(in: statusOutput, range: NSRange(statusOutput.startIndex..., in: statusOutput)),
              let r = Range(m.range(at: 1), in: statusOutput) else { return nil }
        let name = String(statusOutput[r])
        return Address.isValidInterface(name) ? name : nil
    }

    /// Match strictly by UUID. Names are display-only and never used for matching.
    public static func tunnelState(
        services: [ServiceSnapshot], serviceUUID: String, statusOutput: String?
    ) -> TunnelState? {
        guard let s = services.first(where: { $0.uuid == serviceUUID.uppercased() }) else { return nil }
        let iface = s.status == .connected ? statusOutput.flatMap(parseInterface) : nil
        return TunnelState(status: s.status, interface: iface)
    }
}

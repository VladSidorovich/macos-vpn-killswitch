import Foundation

public enum VPNProfile: String, Codable, Sendable {
    /// L2TP/IPsec: UDP 500/4500/1701 and ESP to the endpoint.
    case l2tp
}

public enum EndpointDNS: String, Codable, Sendable {
    /// No DNS while the tunnel is down.
    case none
    /// Port 53 to `resolvers` only, only while the tunnel is down.
    case resolver
}

public struct Config: Codable, Equatable, Sendable {
    public var version: Int
    /// UUID of the SystemConfiguration network service (see `scutil --nc list`).
    public var serviceUUID: String
    /// Human-readable service name.
    public var serviceName: String
    public var profile: VPNProfile
    /// VPN server host names or IP literals. Only IPs ever reach the ruleset.
    public var servers: [String]
    public var endpointDNS: EndpointDNS
    public var resolvers: [String]
    /// Destinations that stay reachable while blocked (e.g. management agents).
    public var exemptDestinations: [String]
    public var allowLAN: Bool
    /// Extra DHCP server addresses to allow (port 67) beyond broadcast and private ranges,
    /// for networks whose DHCP server has a public address.
    public var dhcpServers: [String]
    public var maxPauseSeconds: Int
    /// When true, `off` and `pause` need root.
    public var locked: Bool

    public init(
        version: Int = 1,
        serviceUUID: String,
        serviceName: String,
        profile: VPNProfile = .l2tp,
        servers: [String],
        endpointDNS: EndpointDNS = .resolver,
        resolvers: [String] = [],
        exemptDestinations: [String] = [],
        allowLAN: Bool = false,
        dhcpServers: [String] = [],
        maxPauseSeconds: Int = 1800,
        locked: Bool = true
    ) {
        self.version = version
        self.serviceUUID = serviceUUID
        self.serviceName = serviceName
        self.profile = profile
        self.servers = servers
        self.endpointDNS = endpointDNS
        self.resolvers = resolvers
        self.exemptDestinations = exemptDestinations
        self.allowLAN = allowLAN
        self.dhcpServers = dhcpServers
        self.maxPauseSeconds = maxPauseSeconds
        self.locked = locked
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            version: try c.decodeIfPresent(Int.self, forKey: .version) ?? 1,
            serviceUUID: try c.decode(String.self, forKey: .serviceUUID),
            serviceName: try c.decode(String.self, forKey: .serviceName),
            profile: try c.decodeIfPresent(VPNProfile.self, forKey: .profile) ?? .l2tp,
            servers: try c.decode([String].self, forKey: .servers),
            endpointDNS: try c.decodeIfPresent(EndpointDNS.self, forKey: .endpointDNS) ?? .resolver,
            resolvers: try c.decodeIfPresent([String].self, forKey: .resolvers) ?? [],
            exemptDestinations: try c.decodeIfPresent([String].self, forKey: .exemptDestinations) ?? [],
            allowLAN: try c.decodeIfPresent(Bool.self, forKey: .allowLAN) ?? false,
            dhcpServers: try c.decodeIfPresent([String].self, forKey: .dhcpServers) ?? [],
            maxPauseSeconds: try c.decodeIfPresent(Int.self, forKey: .maxPauseSeconds) ?? 1800,
            locked: try c.decodeIfPresent(Bool.self, forKey: .locked) ?? true
        )
    }

    /// Returns human-readable problems; empty means valid.
    public func validate() -> [String] {
        var errors: [String] = []
        if version != 1 { errors.append("unsupported version \(version)") }
        if UUID(uuidString: serviceUUID) == nil { errors.append("serviceUUID is not a UUID") }
        if serviceName.isEmpty || serviceName.contains("\"") { errors.append("serviceName is empty or contains a quote") }
        if servers.isEmpty { errors.append("servers must not be empty") }
        if endpointDNS == .resolver && resolvers.isEmpty { errors.append("endpointDNS=resolver needs resolvers") }
        for a in resolvers + exemptDestinations where !Address.isValid(a) {
            errors.append("invalid address: \(a)")
        }
        for s in servers where !Address.isValid(s) && !Address.isValidHostname(s) {
            errors.append("invalid server: \(s)")
        }
        for a in dhcpServers where !Address.isValid(a) { errors.append("invalid dhcpServers entry: \(a)") }
        if maxPauseSeconds < 0 { errors.append("maxPauseSeconds must be >= 0") }
        return errors
    }
}

/// Strict syntax checks. Everything that is interpolated into pf rules goes through these.
public enum Address {
    private static let ip = try! NSRegularExpression(pattern: #"\A[0-9a-fA-F:.]+(/[0-9]{1,3})?\z"#)
    private static let host = try! NSRegularExpression(pattern: #"\A[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?)+\z"#)
    private static let iface = try! NSRegularExpression(pattern: #"\A[a-z]{2,8}[0-9]{1,3}\z"#)

    private static func matches(_ r: NSRegularExpression, _ s: String) -> Bool {
        r.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil
    }

    /// IPv4/IPv6 literal, optionally with a prefix length. Must contain a '.' or ':'.
    public static func isValid(_ s: String) -> Bool {
        matches(ip, s) && (s.contains(".") || s.contains(":"))
    }
    public static func isValidHostname(_ s: String) -> Bool { matches(host, s) }
    public static func isValidInterface(_ s: String) -> Bool { matches(iface, s) }
}

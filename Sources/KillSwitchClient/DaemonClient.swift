import Foundation
import KillSwitchCore
import Darwin

public enum ClientError: Error, Equatable {
    case notInstalled          // socket file missing (ENOENT)
    case permissionDenied      // not in the admin group (EACCES)
    case refused               // stale socket, daemon not running (ECONNREFUSED)
    case timeout               // daemon did not answer in time
    case badResponse           // garbage or empty reply
    case other(String)

    public var message: String {
        switch self {
        case .notInstalled: return "killswitchd is not installed (no socket)"
        case .permissionDenied: return "no permission to use the socket (your user must be in the admin group)"
        case .refused: return "killswitchd is not running (stale socket)"
        case .timeout: return "killswitchd did not answer in time"
        case .badResponse: return "killswitchd sent an unreadable answer"
        case let .other(m): return m
        }
    }
}

/// One request per connection, JSON line each way. Never blocks longer than `timeout`.
public struct DaemonClient: Sendable {
    public let path: String
    public let timeout: TimeInterval

    public init(path: String = "/var/run/vpn-killswitch.sock", timeout: TimeInterval = 2) {
        self.path = path
        self.timeout = timeout
    }

    public func send(_ req: IPCRequest) throws -> IPCResponse {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw ClientError.other("socket() failed") }
        defer { close(fd) }

        var tv = timeval(tv_sec: Int(timeout), tv_usec: Int32((timeout - floor(timeout)) * 1_000_000))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8CString)
        guard bytes.count <= MemoryLayout.size(ofValue: addr.sun_path) else {
            throw ClientError.other("socket path is too long")
        }
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            for (i, b) in bytes.enumerated() { raw[i] = UInt8(bitPattern: b) }
        }
        let len = socklen_t(MemoryLayout<sockaddr_un>.size)
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, len) }
        }
        if rc != 0 { throw Self.classify(errno) }

        guard var out = try? JSONEncoder().encode(req) else { throw ClientError.badResponse }
        out.append(10)
        let written = out.withUnsafeBytes { write(fd, $0.baseAddress, out.count) }
        if written < 0 { throw Self.classify(errno) }

        var data = Data()
        var buf = [UInt8](repeating: 0, count: 4096)
        while data.count < 65536 {
            let n = read(fd, &buf, buf.count)
            if n < 0 { throw Self.classify(errno) }
            if n == 0 { break }
            data.append(buf, count: n)
            if data.contains(10) { break }
        }
        guard !data.isEmpty, let resp = try? JSONDecoder().decode(IPCResponse.self, from: data) else {
            throw ClientError.badResponse
        }
        return resp
    }

    static func classify(_ e: Int32) -> ClientError {
        switch e {
        case ENOENT: return .notInstalled
        case EACCES, EPERM: return .permissionDenied
        case ECONNREFUSED: return .refused
        case EAGAIN, ETIMEDOUT: return .timeout
        default: return .other(String(cString: strerror(e)))
        }
    }
}

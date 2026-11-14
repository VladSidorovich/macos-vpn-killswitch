import Foundation
import KillSwitchCore
import KillSwitchDaemon

/// Unix socket, one JSON request per connection. Clients send verbs only,
/// never rule text, hosts or interface names.
final class IPCServer {
    let path: String
    let daemon: Daemon
    let isRootMode: Bool
    private let slots = DispatchSemaphore(value: 4)
    private let workers = DispatchQueue(label: "ipc.workers", attributes: .concurrent)

    init(path: String, daemon: Daemon, rootMode: Bool) {
        self.path = path
        self.daemon = daemon
        self.isRootMode = rootMode
    }

    func start() -> Bool {
        unlink(path)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { log("socket() failed"); return false }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8CString)
        guard bytes.count <= MemoryLayout.size(ofValue: addr.sun_path) else { log("socket path too long"); return false }
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            for (i, b) in bytes.enumerated() { raw[i] = UInt8(bitPattern: b) }
        }
        let len = socklen_t(MemoryLayout<sockaddr_un>.size)
        let ok = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, len) }
        }
        guard ok == 0 else { log("bind failed: \(String(cString: strerror(errno)))"); return false }
        if isRootMode {
            chmod(path, 0o660)
            chown(path, 0, 80)          // group admin
        } else {
            chmod(path, 0o600)
        }
        guard listen(fd, 8) == 0 else { log("listen failed"); return false }
        Thread.detachNewThread { [self] in acceptLoop(fd) }
        log("listening on \(path)")
        return true
    }

    private func acceptLoop(_ listenFD: Int32) {
        while true {
            let c = accept(listenFD, nil, nil)
            if c < 0 {
                if errno != EINTR { log("accept failed: \(String(cString: strerror(errno)))"); sleep(1) }
                continue
            }
            // Handle clients concurrently (bounded) so one stalled client cannot block the rest.
            slots.wait()
            workers.async { [self] in
                serve(c)
                close(c)
                slots.signal()
            }
        }
    }

    private func serve(_ fd: Int32) {
        // Default to "not root" and refuse the connection if the peer cannot be identified.
        var uid: uid_t = uid_t.max, gid: gid_t = gid_t.max
        guard getpeereid(fd, &uid, &gid) == 0 else { log("getpeereid failed; dropping connection"); return }
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        var tv = timeval(tv_sec: 2, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        var buf = [UInt8](repeating: 0, count: 4096)
        var data = Data()
        while data.count < 4096 {
            let n = read(fd, &buf, buf.count)
            if n <= 0 { break }
            data.append(buf, count: n)
            if data.contains(10) { break }
        }
        let resp: IPCResponse
        if let req = try? JSONDecoder().decode(IPCRequest.self, from: data) {
            resp = DispatchQueue.main.sync { daemon.handle(req, peerIsRoot: uid == 0) }
            if req.verb != .status { log("ipc \(req.verb.rawValue) from uid \(uid): \(resp.ok ? "ok" : resp.error ?? "error")") }
        } else {
            resp = IPCResponse(ok: false, error: "bad request")
        }
        if var out = try? JSONEncoder().encode(resp) {
            out.append(10)
            out.withUnsafeBytes { raw in
                var off = 0
                while off < raw.count {
                    let n = write(fd, raw.baseAddress! + off, raw.count - off)
                    if n <= 0 { break }
                    off += n
                }
            }
        }
    }
}

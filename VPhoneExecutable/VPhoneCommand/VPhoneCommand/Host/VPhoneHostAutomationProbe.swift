import Darwin
import Foundation

/// Requests to a running VM's control socket, `vphone.sock`. `vm create` pings
/// through it instead of parsing the VM process's buffered stdout, and
/// `vm network` drives the NIC through it.
enum VPhoneHostAutomationProbe {
    static func ping(socketPath: String) -> Bool {
        send(["t": "ping", "screen": false], socketPath: socketPath)?["ok"] as? Bool == true
    }

    /// One request, one reply line. Nil when the socket is not there or the
    /// reply is not JSON.
    static func send(_ request: [String: Any], socketPath: String, timeout seconds: Int = 2) -> [String: Any]? {
        let path = socketPath.utf8CString
        var address = sockaddr_un()
        guard path.count <= MemoryLayout.size(ofValue: address.sun_path) else { return nil }
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutablePointer(to: &address.sun_path) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: path.count) { destination in
                for (index, byte) in path.enumerated() {
                    destination[index] = byte
                }
            }
        }

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }

        var timeout = timeval(tv_sec: seconds, tv_usec: 0)
        _ = withUnsafePointer(to: &timeout) {
            setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, $0, socklen_t(MemoryLayout<timeval>.size))
        }
        var noSigPipe: Int32 = 1
        _ = withUnsafePointer(to: &noSigPipe) {
            setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, $0, socklen_t(MemoryLayout<Int32>.size))
        }
        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0,
              var request = try? JSONSerialization.data(withJSONObject: request)
        else { return nil }
        request.append(0x0A)
        let written = request.withUnsafeBytes { bytes in
            Darwin.write(fd, bytes.baseAddress, bytes.count)
        }
        guard written == request.count else { return nil }

        var reply = Data()
        var buffer = [UInt8](repeating: 0, count: 512)
        while reply.count < 1 << 20 {
            let count = buffer.withUnsafeMutableBytes { bytes in
                Darwin.read(fd, bytes.baseAddress, bytes.count)
            }
            guard count > 0 else { return nil }
            reply.append(contentsOf: buffer.prefix(count))
            if let newline = reply.firstIndex(of: 0x0A),
               let json = try? JSONSerialization.jsonObject(with: Data(reply[..<newline])) as? [String: Any]
            {
                return json
            }
        }
        return nil
    }
}

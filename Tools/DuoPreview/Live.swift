import AppKit
import Foundation

// A running Duo VM, reached through its host control socket.
enum LiveVM {
    static let socketPath = NSHomeDirectory() + "/.vphone/machines/duo/vphone.sock"

    static func call(_ request: [String: Any]) async -> [String: Any]? {
        guard let body = try? JSONSerialization.data(withJSONObject: request) else { return nil }
        let reply: Data? = await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                continuation.resume(returning: send(body))
            }
        }
        return reply.flatMap { (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any] }
    }

    private static func send(_ body: Data) -> Data? {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            _ = socketPath.utf8CString.withUnsafeBytes { raw.copyMemory(from: UnsafeRawBufferPointer(rebasing: $0.prefix(raw.count))) }
        }
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard connected == 0 else { return nil }
        var line = body
        line.append(0x0A)
        _ = line.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
        var reply = Data()
        var buffer = [UInt8](repeating: 0, count: 65536)
        while !reply.last.map({ $0 == 0x0A }, default: false) {
            let n = read(fd, &buffer, buffer.count)
            if n <= 0 { break }
            reply.append(buffer, count: n)
        }
        return reply
    }

    static func rpc(_ method: String, _ params: [String: Any] = [:]) async -> [String: Any]? {
        await call(["t": "rpc", "method": method, "params": params, "screen": false])
    }

    static func frame() async -> CGImage? {
        let path = NSTemporaryDirectory() + "duo-live-frame.png"
        guard let reply = await call(["t": "screenshot", "path": path, "screen": false]), reply["ok"] as? Bool == true,
              let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil)
        else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }
}

private extension Optional {
    func map<T>(_ transform: (Wrapped) -> T, default value: T) -> T {
        switch self { case let .some(w): transform(w); case .none: value }
    }
}

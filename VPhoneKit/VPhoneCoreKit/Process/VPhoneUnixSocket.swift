import Darwin
import Foundation

// MARK: - Unix Socket

/// A client connection to a Unix-domain stream socket by path: the one place
/// that packs a `sockaddr_un`. Used for a VM's control socket, `vphone.sock`,
/// both to talk to it and to tell a live VM from a stale socket file.
public enum VPhoneUnixSocket {
    public enum ConnectError: Error, Equatable {
        /// The path does not fit `sun_path` with its terminating NUL.
        case pathTooLong
        /// `socket(2)` failed, with its errno.
        case socket(Int32)
        /// `connect(2)` failed, with its errno: ECONNREFUSED for a socket
        /// file nobody listens on, ENOENT for no file, EACCES for one this
        /// user may not write.
        case connect(Int32)
    }

    /// A connected descriptor, which the caller closes.
    public static func connect(to path: String) -> Result<Int32, ConnectError> {
        let bytes = path.utf8CString
        var address = sockaddr_un()
        guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else {
            return .failure(.pathTooLong)
        }
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            for (index, byte) in bytes.enumerated() {
                buffer[index] = UInt8(bitPattern: byte)
            }
        }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return .failure(.socket(errno)) }
        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else {
            let failure = errno
            close(fd)
            return .failure(.connect(failure))
        }
        return .success(fd)
    }
}

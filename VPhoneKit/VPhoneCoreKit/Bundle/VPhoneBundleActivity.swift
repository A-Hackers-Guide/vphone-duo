import Darwin
import Foundation

// MARK: - Activity

/// Whether a machine is in use, for operations that read or replace its state
/// files and need them to stand still: cloning, snapshotting and reverting.
///
/// A running `vphone-vm` keeps the disk image, `SEPStorage` and `nvram.bin`
/// open, and they move together: the SEP's anti-replay counters and the xART
/// gigalocker on the disk advance as a pair. A copy of a running machine can
/// take one at a different moment from the other, and the guest then panics in
/// the SEP on its next boot. So the check looks for any process holding one of
/// the three open, by device and inode rather than path. Another user's process
/// (a VM started under sudo) cannot be inspected without root, so a live
/// `vphone.sock` counts as running too.
public enum VPhoneBundleActivity {
    /// The files a running VM holds open, and the ones a clone, snapshot or
    /// revert must take together, by their names inside the bundle.
    public static func stateFileNames(of bundle: VPhoneBundle) -> [String] {
        [bundle.manifest.diskImage, bundle.manifest.sepStorage, bundle.manifest.nvramStorage]
    }

    /// Throws `VPhoneBundleActivityError.running` unless the machine is stopped.
    public static func requireStopped(_ bundle: VPhoneBundle) throws {
        let urls = stateFileNames(of: bundle).map { bundle.url.appendingPathComponent($0) }
        let pids = processesHolding(urls)
        if !pids.isEmpty || controlSocketAnswers(bundle.url.appendingPathComponent("vphone.sock")) {
            throw VPhoneBundleActivityError.running(name: bundle.name, pids: pids)
        }
    }

    // MARK: - Processes

    /// The processes of this user that have any of `urls` open, sorted. One
    /// pass over the process table, whatever the number of files; a missing
    /// file is held by nobody.
    static func processesHolding(_ urls: [URL]) -> [pid_t] {
        var targets = Set<FileID>()
        for url in urls {
            var info = stat()
            if stat(url.path, &info) == 0 {
                targets.insert(FileID(device: info.st_dev, inode: info.st_ino))
            }
        }
        guard !targets.isEmpty else { return [] }
        return VPhoneGuestProcesses.allPIDs().filter { holds(pid: $0, anyOf: targets) }
    }

    private struct FileID: Hashable {
        let device: dev_t
        let inode: ino_t
    }

    private static func holds(pid: pid_t, anyOf targets: Set<FileID>) -> Bool {
        // EPERM for another user's process: it is skipped, and the socket
        // probe covers the case that matters.
        let size = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard size > 0 else { return false }
        let stride = MemoryLayout<proc_fdinfo>.stride
        var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(size) / stride + 16)
        let filled = fds.withUnsafeMutableBytes { buffer in
            proc_pidinfo(pid, PROC_PIDLISTFDS, 0, buffer.baseAddress, Int32(buffer.count))
        }
        guard filled > 0 else { return false }
        for fd in fds.prefix(Int(filled) / stride) where fd.proc_fdtype == UInt32(PROX_FDTYPE_VNODE) {
            var info = vnode_fdinfo()
            let got = proc_pidfdinfo(pid, fd.proc_fd, PROC_PIDFDVNODEINFO, &info, Int32(MemoryLayout<vnode_fdinfo>.size))
            guard got == Int32(MemoryLayout<vnode_fdinfo>.size) else { continue }
            let st = info.pvi.vi_stat
            if targets.contains(FileID(device: dev_t(st.vst_dev), inode: ino_t(st.vst_ino))) {
                return true
            }
        }
        return false
    }

    // MARK: - Control socket

    /// A stale socket file from a VM that exited refuses the connection.
    private static func controlSocketAnswers(_ url: URL) -> Bool {
        let path = url.path
        var address = sockaddr_un()
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        guard path.utf8.count < capacity else { return false }
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            for (index, byte) in path.utf8.enumerated() {
                buffer[index] = byte
            }
        }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        return result == 0
    }
}

// MARK: - Error

public enum VPhoneBundleActivityError: Error, Equatable {
    case running(name: String, pids: [pid_t])
}

extension VPhoneBundleActivityError: CustomStringConvertible, LocalizedError {
    public var description: String {
        switch self {
        case let .running(name, pids):
            let who = pids.isEmpty ? "" : " (process \(pids.map(String.init).joined(separator: ", ")))"
            return "VM '\(name)' is running\(who). Stop it, then try again."
        }
    }

    public var errorDescription: String? {
        description
    }
}

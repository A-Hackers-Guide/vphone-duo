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
/// (a VM started under sudo) cannot be inspected without root, so a
/// `vphone.sock` counts as running too unless it is missing, not a socket, or
/// refuses the connection as a stale one does. A root-owned socket this user
/// may not connect to is running.
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
        if !pids.isEmpty || controlSocketIsLive(bundle.url.appendingPathComponent("vphone.sock")) {
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
        // probe covers the case that matters (a VM under sudo, whose socket
        // refuses this user with EACCES).
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

    /// Whether `vphone.sock` belongs to a live VM. Only two answers mean it
    /// does not: no socket there (nothing at the path, or something other than
    /// a socket, judged without following a link), and a socket whose
    /// `connect` fails with ECONNREFUSED or ENOENT, the file a VM that exited
    /// leaves behind. Any other failure counts as live: a VM started under
    /// sudo owns its socket as root with mode 0755, so this user's `connect`
    /// fails with EACCES while the VM runs, and its processes are hidden from
    /// `processesHolding` too.
    private static func controlSocketIsLive(_ url: URL) -> Bool {
        var info = stat()
        guard lstat(url.path, &info) == 0, info.st_mode & S_IFMT == S_IFSOCK else { return false }
        switch VPhoneUnixSocket.connect(to: url.path) {
        case let .success(fd):
            close(fd)
            return true
        case let .failure(.connect(failure)):
            return failure != ECONNREFUSED && failure != ENOENT
        case .failure(.pathTooLong), .failure(.socket):
            // A socket that cannot be probed (a path too long for sun_path, or
            // no descriptor to probe with) is there all the same, and calling
            // it stale would let a clone or revert copy or replace the state
            // files of a running guest, so it counts as live; removing a stale
            // one by hand clears the refusal.
            return true
        }
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

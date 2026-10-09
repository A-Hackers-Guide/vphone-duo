import Darwin
import Foundation
import Testing
@testable import VPhoneCoreKit

/// Telling a running machine from a stopped one before its state files are
/// copied or replaced.
struct BundleActivityTests {
    private func makeBundle() throws -> (root: URL, bundle: VPhoneBundle) {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        let rom = root.appendingPathComponent("rom.bin")
        try Data([0xAA]).write(to: rom)
        let bundle = try VPhoneBundleOperations.create(
            .init(name: "vm", cpuCount: 2, memoryMB: 1024, diskSizeGB: 1, romSource: rom, sepromSource: rom),
            in: VPhoneLibrary(root: root),
        )
        try Data([1, 2, 3]).write(to: bundle.url.appendingPathComponent("nvram.bin"))
        return (root, bundle)
    }

    private func isRunning(_ bundle: VPhoneBundle) -> Bool {
        (try? VPhoneBundleActivity.requireStopped(bundle)) == nil
    }

    @Test func `finds this process holding an open file`() throws {
        let (root, bundle) = try makeBundle()
        defer { try? FileManager.default.removeItem(at: root) }
        let disk = bundle.url.appendingPathComponent("Disk.img")

        #expect(!VPhoneBundleActivity.processesHolding([disk]).contains(getpid()))
        let fd = open(disk.path, O_RDONLY)
        #expect(fd >= 0)
        #expect(VPhoneBundleActivity.processesHolding([disk]).contains(getpid()))
        close(fd)
        #expect(!VPhoneBundleActivity.processesHolding([disk]).contains(getpid()))
    }

    @Test func `finds a holder on a device numbered past Int32.max`() throws {
        // /dev is such a device on macOS 27; the scan must match it, not trap.
        let null = URL(fileURLWithPath: "/dev/null")
        let fd = open(null.path, O_RDONLY)
        try #require(fd >= 0)
        defer { close(fd) }
        #expect(VPhoneBundleActivity.processesHolding([null]).contains(getpid()))
    }

    @Test func `a missing file has no holders`() {
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        #expect(VPhoneBundleActivity.processesHolding([missing]).isEmpty)
    }

    @Test func `a stopped machine passes and a held state file refuses`() throws {
        let (root, bundle) = try makeBundle()
        defer { try? FileManager.default.removeItem(at: root) }

        try VPhoneBundleActivity.requireStopped(bundle)
        #expect(!isRunning(bundle))

        for name in ["Disk.img", "SEPStorage", "nvram.bin"] {
            let fd = open(bundle.url.appendingPathComponent(name).path, O_RDONLY)
            #expect(fd >= 0)
            #expect(isRunning(bundle))
            #expect(throws: VPhoneBundleActivityError.running(name: "vm", pids: [getpid()])) {
                try VPhoneBundleActivity.requireStopped(bundle)
            }
            close(fd)
        }
    }

    /// A socket bound and listening at the bundle's `vphone.sock`.
    private func listenAtControlSocket(of bundle: VPhoneBundle) throws -> (fd: Int32, path: String) {
        let path = bundle.url.appendingPathComponent("vphone.sock").path
        // A socket path must fit sun_path; the temporary directory usually does.
        try #require(path.utf8.count < 104)

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        try #require(fd >= 0)
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            for (index, byte) in path.utf8.enumerated() {
                buffer[index] = byte
            }
        }
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        #expect(bound == 0)
        #expect(listen(fd, 1) == 0)
        return (fd, path)
    }

    @Test func `a listening control socket counts as running and a stale one does not`() throws {
        let (root, bundle) = try makeBundle()
        defer { try? FileManager.default.removeItem(at: root) }
        let (fd, path) = try listenAtControlSocket(of: bundle)
        #expect(isRunning(bundle))

        // The socket file outlives the listener, as it does after a crash.
        close(fd)
        #expect(FileManager.default.fileExists(atPath: path))
        #expect(!isRunning(bundle))
    }

    @Test func `a control socket this user may not connect to counts as running`() throws {
        let (root, bundle) = try makeBundle()
        defer { try? FileManager.default.removeItem(at: root) }
        let (fd, path) = try listenAtControlSocket(of: bundle)
        defer { close(fd) }

        // Like a root-owned socket of a VM started under sudo: connect fails
        // with EACCES, here even for the owner, while the listener is up.
        #expect(chmod(path, 0) == 0)
        defer { chmod(path, 0o755) }
        #expect(throws: VPhoneBundleActivityError.running(name: "vm", pids: [])) {
            try VPhoneBundleActivity.requireStopped(bundle)
        }
    }

    @Test func `a control socket path that is not a socket counts as stopped`() throws {
        let (root, bundle) = try makeBundle()
        defer { try? FileManager.default.removeItem(at: root) }
        try Data().write(to: bundle.url.appendingPathComponent("vphone.sock"))
        #expect(!isRunning(bundle))
    }
}

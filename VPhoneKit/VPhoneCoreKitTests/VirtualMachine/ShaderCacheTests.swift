import Darwin
import Foundation
import Testing
@testable import VPhoneCoreKit

struct ShaderCacheTests {
    private func withLayout(_ body: (URL, URL, URL) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let machine = root.appendingPathComponent("Lychee")
        let host = root.appendingPathComponent("HostCache")
        try FileManager.default.createDirectory(at: machine, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try body(machine, host, machine.appendingPathComponent("ShaderCache"))
    }

    private func prepare(_ machine: URL, _ host: URL) throws {
        try VPhoneShaderCache.prepare(machineDirectory: machine, ecid: 123, frameworkCache: host)
    }

    @Test("A running VM holds the ECID lock and a later launch can acquire it after exit")
    func concurrentLaunch() throws {
        try withLayout { machine, host, _ in
            var first: VPhoneShaderCache.Session? = try VPhoneShaderCache.session(machineDirectory: machine, ecid: 123, frameworkCache: host)
            #expect(first != nil)
            #expect(throws: CocoaError.self) {
                try VPhoneShaderCache.session(machineDirectory: machine, ecid: 123, frameworkCache: host)
            }
            try first?.checkpoint()
            first = nil
            let second = try VPhoneShaderCache.session(machineDirectory: machine, ecid: 123, frameworkCache: host)
            try second.checkpoint()
        }
    }

    @Test("Paired cache files survive migration, checkpoint and host cache eviction")
    func preservesCacheAcrossSessions() throws {
        try withLayout { machine, host, cache in
            let task = "task-0123456789012345678901234567890123456789/16777235_530"
            let old = host.appendingPathComponent(task)
            try FileManager.default.createDirectory(at: old, withIntermediateDirectories: true)
            for name in ["functions.list", "functions.data"] {
                try Data("old \(name)".utf8).write(to: old.appendingPathComponent(name))
            }
            try prepare(machine, host)
            for name in ["functions.list", "functions.data"] {
                #expect(try Data(contentsOf: cache.appendingPathComponent(task + "/" + name)) == Data("old \(name)".utf8))
                try Data("new \(name)".utf8).write(to: host.appendingPathComponent(task + "/" + name))
            }
            try VPhoneShaderCache.checkpoint(machineDirectory: machine, frameworkCache: host)
            try FileManager.default.removeItem(at: host)
            try prepare(machine, host)
            for name in ["functions.list", "functions.data"] {
                #expect(try Data(contentsOf: host.appendingPathComponent(task + "/" + name)) == Data("new \(name)".utf8))
            }
            var metadata = stat()
            #expect(lstat(cache.path, &metadata) == 0 && metadata.st_mode & S_IFMT == S_IFDIR)
            #expect(metadata.st_mode & 0o777 == 0o777)
            #expect(lstat(host.path, &metadata) == 0 && metadata.st_mode & S_IFMT == S_IFDIR)
        }
    }

    @Test("Deleting the machine snapshot clears an already managed working cache")
    func deletedSnapshotStartsCold() throws {
        try withLayout { machine, host, cache in
            try prepare(machine, host)
            try Data("compiled".utf8).write(to: host.appendingPathComponent("shader"))
            try VPhoneShaderCache.checkpoint(machineDirectory: machine, frameworkCache: host)
            try FileManager.default.removeItem(at: cache)
            try prepare(machine, host)
            #expect(!FileManager.default.fileExists(atPath: host.appendingPathComponent("shader").path))
            #expect(!FileManager.default.fileExists(atPath: cache.appendingPathComponent("shader").path))
            #expect(try String(contentsOf: host.appendingPathComponent(".host-ecid"), encoding: .utf8) == "123\n")
        }
    }

    @Test("Shutdown does not recreate a snapshot deleted during the session")
    func deletedSnapshotStaysDeleted() throws {
        try withLayout { machine, host, cache in
            let session = try VPhoneShaderCache.session(machineDirectory: machine, ecid: 123, frameworkCache: host)
            try Data("compiled".utf8).write(to: host.appendingPathComponent("shader"))
            try FileManager.default.removeItem(at: cache)
            try session.checkpoint()
            try VPhoneShaderCache.checkpoint(machineDirectory: machine)
            #expect(!FileManager.default.fileExists(atPath: cache.path))
            #expect(FileManager.default.fileExists(atPath: host.appendingPathComponent("shader").path))
        }
    }

    @Test("A hard-linked lock cannot widen an unrelated file's permissions")
    func hardLinkedLock() throws {
        try withLayout { machine, host, _ in
            let outside = machine.appendingPathComponent("outside")
            try Data("private".utf8).write(to: outside)
            #expect(chmod(outside.path, 0o600) == 0)
            #expect(link(outside.path, host.appendingPathExtension("vphone-lock").path) == 0)
            #expect(throws: CocoaError.self) {
                try VPhoneShaderCache.session(machineDirectory: machine, ecid: 123, frameworkCache: host)
            }
            var metadata = stat()
            #expect(lstat(outside.path, &metadata) == 0 && metadata.st_mode & 0o777 == 0o600)
        }
    }

    @Test("A moved machine reseeds its working directory without a path alias")
    func movedMachine() throws {
        try withLayout { machine, host, cache in
            try prepare(machine, host)
            try Data("learned".utf8).write(to: cache.appendingPathComponent("shader"))
            let moved = machine.deletingLastPathComponent().appendingPathComponent("Renamed")
            try FileManager.default.moveItem(at: machine, to: moved)
            try prepare(moved, host)
            #expect(try Data(contentsOf: host.appendingPathComponent("shader")) == Data("learned".utf8))
        }
    }

    @Test("Independent snapshots are replaced whole and never merged")
    func wholeSnapshots() throws {
        try withLayout { machine, host, cache in
            for url in [host, cache] {
                try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
                try Data(url.lastPathComponent.utf8).write(to: url.appendingPathComponent("functions.list"))
                try Data(url.lastPathComponent.utf8).write(to: url.appendingPathComponent("functions.data"))
            }
            try prepare(machine, host)
            for name in ["functions.list", "functions.data"] {
                #expect(try Data(contentsOf: host.appendingPathComponent(name)) == Data("ShaderCache".utf8))
            }
        }
    }

    @Test("A foreign host alias is left intact")
    func foreignAlias() throws {
        try withLayout { machine, host, _ in
            let other = machine.deletingLastPathComponent().appendingPathComponent("OtherCache")
            try FileManager.default.createDirectory(at: other, withIntermediateDirectories: false)
            try FileManager.default.createSymbolicLink(at: host, withDestinationURL: other)
            #expect(throws: CocoaError.self) { try prepare(machine, host) }
            #expect(try FileManager.default.destinationOfSymbolicLink(atPath: host.path) == other.path)
        }
    }

    @Test("A failed checkpoint leaves the previous snapshot intact")
    func checkpointFailure() throws {
        try withLayout { machine, host, cache in
            try prepare(machine, host)
            try Data("preserved".utf8).write(to: cache.appendingPathComponent("shader"))
            try FileManager.default.removeItem(at: host)
            try Data("invalid source".utf8).write(to: host)
            #expect(throws: CocoaError.self) {
                try VPhoneShaderCache.checkpoint(machineDirectory: machine, frameworkCache: host)
            }
            #expect(try Data(contentsOf: cache.appendingPathComponent("shader")) == Data("preserved".utf8))
        }
    }

    @Test("A machine cache alias is rejected without widening its destination")
    func machineAliasRejected() throws {
        try withLayout { machine, host, cache in
            let outside = machine.deletingLastPathComponent().appendingPathComponent("outside")
            try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: false)
            #expect(chmod(outside.path, 0o700) == 0)
            try FileManager.default.createSymbolicLink(at: cache, withDestinationURL: outside)
            #expect(throws: CocoaError.self) { try prepare(machine, host) }
            var metadata = stat()
            #expect(lstat(outside.path, &metadata) == 0 && metadata.st_mode & 0o777 == 0o700)
        }
    }
}

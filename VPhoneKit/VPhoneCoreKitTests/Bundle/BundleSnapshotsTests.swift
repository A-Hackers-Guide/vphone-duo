import Darwin
import Foundation
import Testing
@testable import VPhoneCoreKit

/// Machine disk snapshots: the state files cloned aside and put back while the
/// machine is stopped. The temporary directory is on the boot volume, which is
/// APFS, so every clone here is a real `clonefile`.
struct BundleSnapshotsTests {
    // MARK: - Fixtures

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
        try write([1, 2, 3], to: "Disk.img", in: bundle)
        try write([4, 5, 6], to: "SEPStorage", in: bundle)
        try write([7, 8, 9], to: "nvram.bin", in: bundle)
        try write(Array("receipt-1".utf8), to: "PatchReceipt.plist", in: bundle)
        return (root, bundle)
    }

    private func write(_ bytes: [UInt8], to name: String, in bundle: VPhoneBundle) throws {
        try Data(bytes).write(to: bundle.url.appendingPathComponent(name))
    }

    private func read(_ name: String, in directory: URL) throws -> Data {
        try Data(contentsOf: directory.appendingPathComponent(name))
    }

    private func snapshotDirectory(_ name: String, of bundle: VPhoneBundle) -> URL {
        VPhoneMachineSnapshots.directory(of: bundle).appendingPathComponent(name)
    }

    // MARK: - Create

    @Test func `create clones every present state file byte for byte`() throws {
        let (root, bundle) = try makeBundle()
        defer { try? FileManager.default.removeItem(at: root) }

        let snapshot = try VPhoneMachineSnapshots.create("clean", note: "fresh install", of: bundle)
        let directory = snapshotDirectory("clean", of: bundle)
        for name in ["Disk.img", "SEPStorage", "nvram.bin", "PatchReceipt.plist"] {
            #expect(try read(name, in: directory) == read(name, in: bundle.url), "\(name)")
        }
        #expect(snapshot.files == ["Disk.img", "SEPStorage", "nvram.bin", "PatchReceipt.plist"])
        #expect(snapshot.absentFiles == ["restore-info.json"])
        #expect(snapshot.note == "fresh install")
        // Settings and Launchpad's binding are not part of it.
        #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("config.plist").path))
        #expect(FileManager.default.fileExists(
            atPath: directory.appendingPathComponent(VPhoneMachineSnapshots.metadataFileName).path,
        ))
        // No staging directory is left beside it.
        let entries = try FileManager.default.contentsOfDirectory(atPath: VPhoneMachineSnapshots.directory(of: bundle).path)
        #expect(entries == ["clean"])
    }

    @Test func `create refuses a machine with no nvram yet`() throws {
        let (root, bundle) = try makeBundle()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.removeItem(at: bundle.url.appendingPathComponent("nvram.bin"))

        #expect(throws: VPhoneMachineSnapshotError.missingStateFile(machine: "vm", file: "nvram.bin")) {
            try VPhoneMachineSnapshots.create("early", of: bundle)
        }
        #expect(!FileManager.default.fileExists(atPath: VPhoneMachineSnapshots.directory(of: bundle).path))
    }

    @Test func `duplicate and invalid names are refused`() throws {
        let (root, bundle) = try makeBundle()
        defer { try? FileManager.default.removeItem(at: root) }

        try VPhoneMachineSnapshots.create("one", of: bundle)
        #expect(throws: VPhoneMachineSnapshotError.alreadyExists(machine: "vm", name: "one")) {
            try VPhoneMachineSnapshots.create("one", of: bundle)
        }
        for bad in ["", "a/b", ".hidden", ".."] {
            #expect(throws: VPhoneMachineSnapshotError.invalidName(bad)) {
                try VPhoneMachineSnapshots.create(bad, of: bundle)
            }
        }
        #expect(try VPhoneMachineSnapshots.list(of: bundle).map(\.name) == ["one"])
    }

    @Test func `create and revert refuse while a state file is held open`() throws {
        let (root, bundle) = try makeBundle()
        defer { try? FileManager.default.removeItem(at: root) }
        try VPhoneMachineSnapshots.create("before", of: bundle)

        let fd = open(bundle.url.appendingPathComponent("SEPStorage").path, O_RDONLY)
        #expect(fd >= 0)
        defer { close(fd) }
        let running = VPhoneBundleActivityError.running(name: "vm", pids: [getpid()])
        #expect(throws: running) {
            try VPhoneMachineSnapshots.create("during", of: bundle)
        }
        #expect(throws: running) {
            try VPhoneMachineSnapshots.revert(to: "before", of: bundle)
        }
        #expect(try VPhoneMachineSnapshots.list(of: bundle).map(\.name) == ["before"])
        // Nothing staged in the machine folder either.
        let hidden = try FileManager.default.contentsOfDirectory(atPath: bundle.url.path).filter { $0.hasPrefix(".snapshot") }
        #expect(hidden.isEmpty)
    }

    // MARK: - List

    @Test func `list is oldest first with metadata`() throws {
        let (root, bundle) = try makeBundle()
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(try VPhoneMachineSnapshots.list(of: bundle).isEmpty)

        let base = Date(timeIntervalSince1970: 1_800_000_000)
        try VPhoneMachineSnapshots.create("zeta", note: "first", of: bundle, now: base)
        try VPhoneMachineSnapshots.create("alpha", of: bundle, now: base.addingTimeInterval(60))
        try VPhoneMachineSnapshots.create("mid", note: "", of: bundle, now: base.addingTimeInterval(30))
        // Something that is not a snapshot is not listed.
        try FileManager.default.createDirectory(
            at: snapshotDirectory("stray", of: bundle),
            withIntermediateDirectories: true,
        )

        let listed = try VPhoneMachineSnapshots.list(of: bundle)
        #expect(listed.map(\.name) == ["zeta", "mid", "alpha"])
        #expect(listed.map(\.created) == [base, base.addingTimeInterval(30), base.addingTimeInterval(60)])
        #expect(listed.map(\.note) == ["first", nil, nil])
    }

    // MARK: - Revert

    @Test func `revert restores the state files and leaves config alone`() throws {
        let (root, bundle) = try makeBundle()
        defer { try? FileManager.default.removeItem(at: root) }
        try VPhoneMachineSnapshots.create("before", of: bundle)

        // The guest runs on: the disk, SEP and NVRAM move, a later install
        // records itself, and the owner changes a setting.
        try write([9, 9, 9, 9], to: "Disk.img", in: bundle)
        try write([8, 8], to: "SEPStorage", in: bundle)
        try write([7], to: "nvram.bin", in: bundle)
        try write(Array("receipt-2".utf8), to: "PatchReceipt.plist", in: bundle)
        try write(Array("{}".utf8), to: "restore-info.json", in: bundle)
        let updated = try VPhoneBundleOperations.updateConfig(
            bundleNamed: "vm",
            in: VPhoneLibrary(root: root),
            cpuCount: 6,
            memoryMB: nil,
        )
        let config = try read("config.plist", in: bundle.url)

        try VPhoneMachineSnapshots.revert(to: "before", of: updated)

        #expect(try read("Disk.img", in: bundle.url) == Data([1, 2, 3]))
        #expect(try read("SEPStorage", in: bundle.url) == Data([4, 5, 6]))
        #expect(try read("nvram.bin", in: bundle.url) == Data([7, 8, 9]))
        #expect(try read("PatchReceipt.plist", in: bundle.url) == Data("receipt-1".utf8))
        // Absent when the snapshot was taken, so absent again.
        #expect(!FileManager.default.fileExists(atPath: bundle.url.appendingPathComponent("restore-info.json").path))
        #expect(try read("config.plist", in: bundle.url) == config)
        #expect(try VPhoneBundle.load(at: bundle.url).manifest.cpuCount == 6)

        // The snapshot is kept, unchanged, and can be used again.
        #expect(try VPhoneMachineSnapshots.list(of: bundle).map(\.name) == ["before"])
        #expect(try read("Disk.img", in: snapshotDirectory("before", of: bundle)) == Data([1, 2, 3]))
        try write([0], to: "Disk.img", in: bundle)
        try VPhoneMachineSnapshots.revert(to: "before", of: bundle)
        #expect(try read("Disk.img", in: bundle.url) == Data([1, 2, 3]))

        let hidden = try FileManager.default.contentsOfDirectory(atPath: bundle.url.path).filter { $0.hasPrefix(".") }
        #expect(hidden.isEmpty)
    }

    @Test func `revert of a damaged snapshot leaves the live files intact`() throws {
        let (root, bundle) = try makeBundle()
        defer { try? FileManager.default.removeItem(at: root) }
        try VPhoneMachineSnapshots.create("broken", of: bundle)
        try FileManager.default.removeItem(at: snapshotDirectory("broken", of: bundle).appendingPathComponent("nvram.bin"))
        try write([5, 5], to: "Disk.img", in: bundle)

        #expect(throws: VPhoneMachineSnapshotError.self) {
            try VPhoneMachineSnapshots.revert(to: "broken", of: bundle)
        }
        #expect(try read("Disk.img", in: bundle.url) == Data([5, 5]))
        let hidden = try FileManager.default.contentsOfDirectory(atPath: bundle.url.path).filter { $0.hasPrefix(".") }
        #expect(hidden.isEmpty)
    }

    @Test func `unknown snapshots are reported`() throws {
        let (root, bundle) = try makeBundle()
        defer { try? FileManager.default.removeItem(at: root) }
        let missing = VPhoneMachineSnapshotError.notFound(machine: "vm", name: "nope")
        #expect(throws: missing) { try VPhoneMachineSnapshots.revert(to: "nope", of: bundle) }
        #expect(throws: missing) { try VPhoneMachineSnapshots.delete("nope", of: bundle) }
    }

    // MARK: - Delete

    @Test func `delete removes the snapshot with files a client added`() throws {
        let (root, bundle) = try makeBundle()
        defer { try? FileManager.default.removeItem(at: root) }
        try VPhoneMachineSnapshots.create("keep", of: bundle)
        try VPhoneMachineSnapshots.create("drop", of: bundle)
        let extra = snapshotDirectory("drop", of: bundle).appendingPathComponent("launchpad.json")
        try Data(#"{"bundle":"2.7.0"}"#.utf8).write(to: extra)

        // A revert keeps the client's file where it was.
        try VPhoneMachineSnapshots.revert(to: "drop", of: bundle)
        #expect(FileManager.default.fileExists(atPath: extra.path))
        #expect(FileManager.default.fileExists(atPath: bundle.url.appendingPathComponent("launchpad.json").path) == false)

        try VPhoneMachineSnapshots.delete("drop", of: bundle)
        #expect(!FileManager.default.fileExists(atPath: snapshotDirectory("drop", of: bundle).path))
        #expect(try VPhoneMachineSnapshots.list(of: bundle).map(\.name) == ["keep"])

        // The last one takes the empty Snapshots folder with it.
        try VPhoneMachineSnapshots.delete("keep", of: bundle)
        #expect(!FileManager.default.fileExists(atPath: VPhoneMachineSnapshots.directory(of: bundle).path))
        #expect(try read("Disk.img", in: bundle.url) == Data([1, 2, 3]))
    }

    // MARK: - Export

    @Test func `snapshots are excluded from export`() {
        let patterns = VPhoneBundleOperations.exportExcludePatterns
        #expect(patterns.contains { fnmatch($0, VPhoneMachineSnapshots.directoryName, 0) == 0 })
        #expect(patterns.contains { fnmatch($0, ".snapshot-revert-1234", 0) == 0 })
        for kept in ["Disk.img", "SEPStorage", "nvram.bin", "config.plist", "PatchReceipt.plist"] {
            #expect(!patterns.contains { fnmatch($0, kept, 0) == 0 }, "\(kept)")
        }
    }
}

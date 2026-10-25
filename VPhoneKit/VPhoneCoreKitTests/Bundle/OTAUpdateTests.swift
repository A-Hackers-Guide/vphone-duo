import Darwin
import Foundation
import Testing
@testable import VPhoneCoreKit

struct OTAUpdateTests {
    @Test func `OTA removal baseline distinguishes placeholders from deliberately reinstalled apps`() throws {
        func row(_ id: String, installed: Bool, placeholder: Bool) -> [String: Any] {
            ["bundle_id": id, "installed": installed, "placeholder": placeholder,
             "registered": installed || placeholder, "restorable": true]
        }
        let absent = row("com.apple.news", installed: false, placeholder: false)
        let placeholder = row("com.apple.MobileSMS", installed: false, placeholder: true)
        let reinstalled = row("com.apple.tv", installed: true, placeholder: false)
        let inventory: [String: Any] = ["backups": [absent, placeholder, reinstalled]]
        #expect(try VPhoneOTAUpdate.removedSystemAppIDs(inventory) == ["com.apple.MobileSMS", "com.apple.news"])
        #expect(throws: VPhoneOTAUpdate.Failure.self) {
            try VPhoneOTAUpdate.requireRemovedSystemApps(["com.apple.MobileSMS"], inventory: inventory)
        }
        try VPhoneOTAUpdate.requireRemovedSystemApps(["com.apple.news"], inventory: inventory)
        #expect(throws: VPhoneOTAUpdate.Failure.self) {
            try VPhoneOTAUpdate.requireRemovedSystemApps(["com.apple.Home"], inventory: inventory)
        }
        #expect(throws: VPhoneOTAUpdate.Failure.self) {
            _ = try VPhoneOTAUpdate.removedSystemAppIDs(["backups": [["bundle_id": "com.apple.news", "restorable": true]]])
        }
        var corrupt = absent
        corrupt["error"] = "Invalid manifest"
        #expect(throws: VPhoneOTAUpdate.Failure.self) {
            _ = try VPhoneOTAUpdate.removedSystemAppIDs(["backups": [corrupt]])
        }
        #expect(throws: VPhoneOTAUpdate.Failure.self) {
            try VPhoneOTAUpdate.requireRemovedSystemApps(["com.apple.news"], inventory: ["backups": [corrupt]])
        }
    }

    private func fixture() throws -> (URL, VPhoneBundle) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let rom = root.appendingPathComponent("rom.bin")
        try Data([0xAA]).write(to: rom)
        let bundle = try VPhoneBundleOperations.create(
            .init(name: "test", cpuCount: 2, memoryMB: 4096, diskSizeGB: 1, romSource: rom, sepromSource: rom),
            in: VPhoneLibrary(root: root))
        for name in ["Disk.img", "SEPStorage", "nvram.bin", "PatchPlan.plist", "PatchSelection.plist"] {
            try Data("old-\(name)".utf8).write(to: bundle.url.appendingPathComponent(name))
        }
        try VPhoneOTAUpdate.withLock(of: bundle) {
            try VPhoneOTAUpdate.capture(.init(bundle: bundle, build: "24A446", version: "27.0.1", source: Data("{}".utf8)), of: bundle)
        }
        return (root, bundle)
    }

    @Test func `OTA rollback restores host selection and config with all three disk state files`() throws {
        let (root, bundle) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let config = try Data(contentsOf: bundle.configURL)
        let oldTree = bundle.url.appendingPathComponent("old_Restore")
        try FileManager.default.createDirectory(at: oldTree, withIntermediateDirectories: false)
        try Data("original kernel".utf8).write(to: oldTree.appendingPathComponent("kernel"))
        try VPhoneOTAUpdate.checkpoint(of: bundle)
        var record = try VPhoneOTAUpdate.read(of: bundle)
        record.phase = .quiesced
        try VPhoneOTAUpdate.write(record, of: bundle)
        try VPhoneOTAUpdate.beginPreparation(of: bundle)
        #expect(!FileManager.default.fileExists(atPath: oldTree.path))
        for name in ["Disk.img", "SEPStorage", "nvram.bin", "config.plist", "PatchPlan.plist", "PatchSelection.plist", "OpenAVB.bin"] {
            try Data("new".utf8).write(to: bundle.url.appendingPathComponent(name))
        }
        try VPhoneOTAUpdate.rollback(of: bundle)
        #expect(try Data(contentsOf: bundle.configURL) == config)
        for name in ["Disk.img", "SEPStorage", "nvram.bin", "PatchPlan.plist", "PatchSelection.plist"] {
            #expect(try Data(contentsOf: bundle.url.appendingPathComponent(name)) == Data("old-\(name)".utf8))
        }
        #expect(try String(contentsOf: oldTree.appendingPathComponent("kernel"), encoding: .utf8) == "original kernel")
        #expect(!FileManager.default.fileExists(atPath: bundle.url.appendingPathComponent("OpenAVB.bin").path))
        #expect(try VPhoneOTAUpdate.read(of: bundle).phase == .rolledBack)
        try VPhoneOTAUpdate.rollback(of: bundle)
        #expect(try VPhoneMachineSnapshots.list(of: bundle).count == 1)
    }

    @Test func `checkpoint and preparation can resume without making more disk snapshots`() throws {
        let (root, bundle) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        try VPhoneOTAUpdate.checkpoint(of: bundle)
        try VPhoneOTAUpdate.checkpoint(of: bundle)
        var record = try VPhoneOTAUpdate.read(of: bundle)
        record.phase = .quiesced
        try VPhoneOTAUpdate.write(record, of: bundle)
        try VPhoneOTAUpdate.beginPreparation(of: bundle)
        let partial = bundle.url.appendingPathComponent("target_Restore")
        try FileManager.default.createDirectory(at: partial, withIntermediateDirectories: false)
        try VPhoneOTAUpdate.beginPreparation(of: bundle)
        #expect(!FileManager.default.fileExists(atPath: partial.path))
        #expect(try VPhoneMachineSnapshots.list(of: bundle).count == 1)
    }

    @Test func `running guest blocks checkpoint and rollback before touching host files`() throws {
        let (root, bundle) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        try VPhoneOTAUpdate.checkpoint(of: bundle)
        let fd = open(bundle.url.appendingPathComponent("SEPStorage").path, O_RDONLY)
        defer { close(fd) }
        #expect(throws: VPhoneBundleActivityError.self) { try VPhoneOTAUpdate.checkpoint(of: bundle) }
        #expect(throws: VPhoneBundleActivityError.self) { try VPhoneOTAUpdate.rollback(of: bundle) }
        #expect(try VPhoneOTAUpdate.read(of: bundle).phase == .checkpointed)
    }

    @Test func `journal refuses path injection and another machine`() throws {
        let (root, bundle) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        var record = try VPhoneOTAUpdate.read(of: bundle)
        record.artifacts = ["../escape_Restore"]
        try VPhoneOTAUpdate.write(record, of: bundle)
        #expect(throws: VPhoneOTAUpdate.Failure.self) { try VPhoneOTAUpdate.read(of: bundle) }
        record.artifacts = []
        record.hostFiles = ["../config.plist"]
        try VPhoneOTAUpdate.write(record, of: bundle)
        #expect(throws: VPhoneOTAUpdate.Failure.self) { try VPhoneOTAUpdate.read(of: bundle) }
    }

    @Test func `cannot overwrite recovery journal or prepare before a checkpoint`() throws {
        let (root, bundle) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let record = try VPhoneOTAUpdate.read(of: bundle)
        #expect(throws: VPhoneOTAUpdate.Failure.self) { try VPhoneOTAUpdate.capture(record, of: bundle) }
        #expect(throws: VPhoneOTAUpdate.Failure.self) { try VPhoneOTAUpdate.beginPreparation(of: bundle) }
        #expect(throws: VPhoneOTAUpdate.Failure.self) { try VPhoneOTAUpdate.rollback(of: bundle) }
    }

    @Test func `a new attempt archives a rolled back journal and retains its snapshot`() throws {
        let (root, bundle) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        try VPhoneOTAUpdate.checkpoint(of: bundle)
        let previous = try VPhoneOTAUpdate.read(of: bundle)
        try VPhoneOTAUpdate.rollback(of: bundle)
        let next = VPhoneOTAUpdate.Record(bundle: bundle, build: "24A446", version: "27.0.1", source: Data("{}".utf8))
        try VPhoneOTAUpdate.withLock(of: bundle) { try VPhoneOTAUpdate.capture(next, of: bundle) }
        #expect(try VPhoneOTAUpdate.read(of: bundle).snapshot == next.snapshot)
        let archived = VPhoneOTAUpdate.directory(of: bundle).deletingLastPathComponent()
            .appendingPathComponent(bundle.name + "-" + previous.snapshot + "/Update.plist")
        #expect(FileManager.default.fileExists(atPath: archived.path))
        #expect(try VPhoneMachineSnapshots.list(of: bundle).map(\.name) == [previous.snapshot])
    }

    @Test func `only successful migration for the running target build passes`() throws {
        func verify(_ result: [String: Any]?, done: Bool? = true, version: String? = "27.0.1") throws {
            try VPhoneOTAUpdate.requireMigration(version: "27.0.1", build: "24A446", actualVersion: version,
                                                 migrationDone: done, result: result)
        }
        try verify(["success": true, "buildVersion": "24A446"])
        for result: [String: Any]? in [nil, [:], ["success": true, "buildVersion": "23G90"],
                                       ["success": false, "buildVersion": "24A446"], ["buildVersion": "24A446"]] {
            #expect(throws: VPhoneOTAUpdate.Failure.self) { try verify(result) }
        }
        #expect(throws: VPhoneOTAUpdate.Failure.self) { try verify(["success": true, "buildVersion": "24A446"], done: false) }
        #expect(throws: VPhoneOTAUpdate.Failure.self) { try verify(["success": true, "buildVersion": "24A446"], version: "26.6.2") }
    }

    @Test func `coordinator must own the recovery journal before using it`() throws {
        let (root, bundle) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        var record = try VPhoneOTAUpdate.read(of: bundle)
        #expect(throws: VPhoneOTAUpdate.Failure.self) { try VPhoneOTAUpdate.requireOperation("operation123", record: record) }
        record.operationID = "operation123"
        try VPhoneOTAUpdate.requireOperation("operation123", record: record)
        #expect(throws: VPhoneOTAUpdate.Failure.self) { try VPhoneOTAUpdate.requireOperation("other456", record: record) }
        try VPhoneOTAUpdate.requireOperation(nil, record: record) // explicit local maintenance
    }

    @Test func `network is isolated until commit which preserves target ROM and source resource settings`() throws {
        let (root, bundle) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = bundle.manifest
        try VPhoneOTAUpdate.checkpoint(of: bundle)
        try VPhoneOTAUpdate.isolateNetwork(of: bundle)
        let offline = try VPhoneBundle.load(at: bundle.url)
        #expect(offline.manifest.networkConfig.mode == .off)
        #expect(offline.manifest.networkConfig.macAddress == source.networkConfig.macAddress)
        var record = try VPhoneOTAUpdate.read(of: bundle)
        #expect(record.networkIsolated == true)
        #expect(throws: VPhoneOTAUpdate.Failure.self) { try VPhoneOTAUpdate.commit(of: offline) }
        record.phase = .completed
        try VPhoneOTAUpdate.write(record, of: offline)
        try VPhoneOTAUpdate.commit(of: offline)
        let committed = try VPhoneBundle.load(at: bundle.url)
        #expect(committed.manifest.networkConfig == source.networkConfig)
        #expect(committed.manifest.cpuCount == source.cpuCount)
        #expect(committed.manifest.memorySize == source.memorySize)
        #expect(try VPhoneOTAUpdate.read(of: bundle).phase == .committed)
        try VPhoneOTAUpdate.commit(of: committed)
        #expect(throws: VPhoneOTAUpdate.Failure.self) { try VPhoneOTAUpdate.rollback(of: committed) }
        #expect(try VPhoneOTAUpdate.read(of: bundle).phase == .committed)
    }
}

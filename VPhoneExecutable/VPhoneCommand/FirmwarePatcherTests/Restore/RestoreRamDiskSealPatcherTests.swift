@testable import FirmwarePatcher
import Foundation
import Img4tool
import Testing
import VPhonePatchKit

@Suite("Restore ramdisk APFS seal compatibility")
struct RestoreRamDiskSealPatcherTests {
    @Test(arguments: [UInt32(1), UInt32(0x106)])
    func `hash type comes from the manifest-selected SystemVolume IM4P`(_ hashType: UInt32) throws {
        let root = try rootHashFixture(hashType: hashType)
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(try RestoreRamDiskSealPatcher.systemVolumeHashType(in: root) == hashType)
    }

    @Test
    func `unknown SystemVolume hash type fails closed`() throws {
        let root = try rootHashFixture(hashType: 0x107)
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(throws: PatcherError.self) {
            _ = try RestoreRamDiskSealPatcher.systemVolumeHashType(in: root)
        }
    }

    @Test
    func `root hash digest length must match the known format`() throws {
        let root = try rootHashFixture(hashType: 1, digestLength: 16)
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(throws: PatcherError.self) {
            _ = try RestoreRamDiskSealPatcher.systemVolumeHashType(in: root)
        }
    }

    @Test(arguments: [UInt32(1), UInt32(0x106)])
    func `root hash metadata changes applicability without rewriting the plan`(_ hashType: UInt32) throws {
        let root = try rootHashFixture(hashType: hashType)
        defer { try? FileManager.default.removeItem(at: root) }
        let pipeline = FirmwarePipeline(
            vmDirectory: root,
            variant: .jb,
            verbose: false,
            preset: FirmwarePatchSetCatalog.standardPreset,
        )
        let plan = try #require(try pipeline.resolvePlan(
            iOSBase: VPhoneVersion("27.0.1"),
            cloudOS: VPhoneVersion("26.4"),
        ))
        try pipeline.resolveFirmwareApplicability(
            restoreDir: root,
            iOSBase: VPhoneVersion("27.0.1"),
            cloudOS: VPhoneVersion("26.4"),
            plan: plan,
        )
        let identifier = RestoreRamDiskSealPatcher.patchIdentifier
        #expect(plan.isEnabled(identifier))
        #expect(pipeline.notApplicablePatches.contains(identifier) == (hashType == 1))
        let components = try pipeline.buildComponentList(
            restoreDir: root,
            iOSBase: VPhoneVersion("27.0.1"),
            plan: plan,
            gate: VPhonePatchGate(plan: plan),
        )
        let count = components
            .filter { $0.name == "RestoreRamDisk" || $0.name == "RestoreTrustCache" }
            .reduce(0) { $0 + $1.patcherFactories.count }
        #expect(count == (hashType == 0x106 ? 2 : 0))
    }

    @Test
    func `v1 trust cache replacement stays sorted and preserves metadata`() throws {
        let oldHash = Data(repeating: 0x20, count: 20)
        let newHash = Data(repeating: 0x05, count: 20)
        let low = Data(repeating: 0x10, count: 20)
        let high = Data(repeating: 0x30, count: 20)

        var cache = Data()
        append(UInt32(1), to: &cache)
        cache.append(Data(repeating: 0xAB, count: 16))
        append(UInt32(3), to: &cache)
        cache.append(entry(low, hashType: 2, flags: 1))
        cache.append(entry(oldHash, hashType: 2, flags: 7))
        cache.append(entry(high, hashType: 2, flags: 3))

        let result = try RestoreTrustCacheSealPatcher.replacingCDHash(
            in: cache,
            from: oldHash,
            to: newHash,
        )
        #expect(result.changedRange == 24 ..< 24 + 44)
        #expect(result.data.prefix(24) == cache.prefix(24))
        #expect(cache[result.changedRange] != result.data[result.changedRange])

        let entries = (0 ..< 3).map { index in
            Data(result.data[24 + index * 22 ..< 24 + (index + 1) * 22])
        }
        #expect(entries.map { Data($0.prefix(20)) } == [newHash, low, high])
        #expect(entries[0].suffix(2) == Data([2, 7]))
        #expect(entries[1].suffix(2) == Data([2, 1]))
        #expect(entries[2].suffix(2) == Data([2, 3]))
    }

    @Test
    func `v1 trust cache requires exactly one old cdhash`() throws {
        let oldHash = Data(repeating: 0x20, count: 20)
        let newHash = Data(repeating: 0x21, count: 20)
        var cache = Data()
        append(UInt32(1), to: &cache)
        cache.append(Data(repeating: 0, count: 16))
        append(UInt32(1), to: &cache)
        cache.append(entry(Data(repeating: 0x10, count: 20), hashType: 2, flags: 0))

        #expect(throws: (any Error).self) {
            try RestoreTrustCacheSealPatcher.replacingCDHash(in: cache, from: oldHash, to: newHash)
        }
    }

    private func entry(_ hash: Data, hashType: UInt8, flags: UInt8) -> Data {
        var result = hash
        result.append(hashType)
        result.append(flags)
        return result
    }

    private func append(_ value: UInt32, to data: inout Data) {
        withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
    }

    private func rootHashFixture(hashType: UInt32, digestLength: UInt32 = 32) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("vphone-root-hash-test-\(UUID().uuidString)", isDirectory: true)
        let path = "Firmware/selected.root_hash"
        let file = root.appending(path: path)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        var payload = Data(repeating: 0, count: 208)
        payload.replaceSubrange(8 ..< 12, with: withUnsafeBytes(of: hashType.littleEndian) { Data($0) })
        payload.replaceSubrange(12 ..< 16, with: withUnsafeBytes(of: digestLength.littleEndian) { Data($0) })
        try IM4P(fourcc: "isys", description: "0", payload: payload).data.write(to: file)
        var decoy = payload
        let other: UInt32 = hashType == 1 ? 0x106 : 1
        decoy.replaceSubrange(8 ..< 12, with: withUnsafeBytes(of: other.littleEndian) { Data($0) })
        try IM4P(fourcc: "isys", description: "0", payload: decoy).data
            .write(to: root.appending(path: "Firmware/decoy.root_hash"))
        let manifest: [String: Any] = [
            "BuildIdentities": [[
                "Manifest": [
                    "SystemVolume": ["Info": ["Path": path]],
                    "RestoreRamDisk": ["Info": ["Path": "Firmware/ramdisk.dmg"]],
                    "RestoreTrustCache": ["Info": ["Path": "Firmware/trustcache.im4p"]],
                ],
            ]],
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: manifest, format: .xml, options: 0)
        try data.write(to: root.appending(path: "BuildManifest.plist"))
        return root
    }
}

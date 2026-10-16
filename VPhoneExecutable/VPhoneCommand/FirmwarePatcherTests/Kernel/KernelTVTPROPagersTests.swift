@testable import FirmwarePatcher
import Foundation
import Testing
import VPhonePatchKit

@Suite("TV TPRO pager tunable")
struct KernelTVTPROPagersTests {
    static let segments = [
        MachOSegmentInfo(name: "__KLDDATA", vmAddr: 0, vmSize: 256, fileOffset: 0, fileSize: 256),
        MachOSegmentInfo(name: "__DATA", vmAddr: 256, vmSize: 64, fileOffset: 256, fileSize: 64),
        MachOSegmentInfo(name: "__TEXT_EXEC", vmAddr: 320, vmSize: 64, fileOffset: 320, fileSize: 64),
    ]

    func fixture() -> Data {
        var data = Data(repeating: 0, count: 384)
        data.replaceSubrange(16..<33, with: Data("sprr_tpro_pagers\0".utf8))
        // Name occupies 17 bytes; preserve descriptor alignment independently.
        put(&data, 64, 0x0010_0000_0000_0010)
        put(&data, 72, 0x0040_0000_0000_0100)
        put(&data, 80, 4)
        put(&data, 128, 1)
        put(&data, 136, 0x8010_2ABE_0000_0140)
        put(&data, 144, 0x0020_0000_0000_0040)
        put(&data, 256, 1)
        return data
    }

    func put(_ data: inout Data, _ offset: Int, _ value: UInt64) {
        var value = value.littleEndian
        withUnsafeBytes(of: &value) { data.replaceSubrange(offset..<offset+8, with: $0) }
    }

    @Test func validatesDescriptorAndRegistration() {
        let data = fixture()
        #expect(KernelCustomFirmwarePatcher.tvTPROPagersDefault(in: data, segments: Self.segments) == 256)
    }

    @Test func acceptsAlreadyZeroDefault() {
        var data = fixture()
        put(&data, 256, 0)
        #expect(KernelCustomFirmwarePatcher.tvTPROPagersDefault(in: data, segments: Self.segments) == 256)
    }

    @Test func blockedPatchLeavesBytesUnchanged() {
        let data = fixture()
        let patcher = KernelCustomFirmwarePatcher(data: data, verbose: false)
        patcher.segments = Self.segments
        patcher.gate = VPhonePatchGate(declared: [FirmwareKernelCustomFirmwarePatchSet.tvTPROPagers], enabled: [])
        #expect(patcher.patchTVTPROPagers())
        #expect(patcher.patches.isEmpty)
        #expect(patcher.buffer.data == data)
    }

    @Test func rejectsInvalidDescriptorsAndRegistrations() {
        for (offset, value) in [(80, UInt64(8)), (80, 0x100000004), (72, 0x40000100), (72, 320), (128, 2), (136, 256), (144, 65), (256, 2)] {
            var data = fixture()
            put(&data, offset, value)
            #expect(KernelCustomFirmwarePatcher.tvTPROPagersDefault(in: data, segments: Self.segments) == nil)
        }
    }

    @Test func rejectsAmbiguousRegistrationAndTruncation() {
        var data = fixture()
        data.replaceSubrange(160..<184, with: data[128..<152])
        #expect(KernelCustomFirmwarePatcher.tvTPROPagersDefault(in: data, segments: Self.segments) == nil)
        #expect(KernelCustomFirmwarePatcher.tvTPROPagersDefault(in: Data(), segments: []) == nil)
        // Segment metadata can claim bytes beyond EOF; do not trust it as a
        // substitute for bounding the integer read against the actual file.
        let truncated = fixture().prefix(258)
        #expect(KernelCustomFirmwarePatcher.tvTPROPagersDefault(in: Data(truncated), segments: Self.segments) == nil)
    }

    @Test func nativeResearchKernelWhenPresent() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let url = root.appendingPathComponent(".build/tvos-research/kernel-dec/kernelcache.research.vphone600.decompressed")
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        let data = try Data(contentsOf: url)
        let patcher = KernelCustomFirmwarePatcher(data: data, verbose: false)
        patcher.parseMachO()
        #expect(patcher.patchTVTPROPagers())
        let record = try #require(patcher.patches.first)
        #expect(record.originalBytes == Data([1, 0, 0, 0]))
        #expect(record.patchedBytes == Data(repeating: 0, count: 4))
        var expected = data
        expected.replaceSubrange(record.fileOffset..<record.fileOffset+4, with: record.patchedBytes)
        #expect(patcher.buffer.data == expected)
    }
}

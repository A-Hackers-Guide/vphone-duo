@testable import FirmwarePatcher
import Foundation
import Testing

@Suite("Restore ramdisk APFS seal compatibility")
struct RestoreRamDiskSealPatcherTests {
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
}

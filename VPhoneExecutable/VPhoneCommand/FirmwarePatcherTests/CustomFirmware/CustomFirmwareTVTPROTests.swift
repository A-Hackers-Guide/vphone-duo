@testable import FirmwarePatcher
import Foundation
import Testing
import VPhonePatchKit

@Suite("TV dyld TPRO parameter compatibility")
struct CustomFirmwareTVTPROTests {
    // Independent native instruction windows from 23L5208m TV dyld. Their
    // real ADRP/ADD, BL and presence tests survive relocation in this fixture.
    static let processAddress = 0x240DC
    static let stackAddress = 0x249FC
    static let cacheAddress = 0x25CD8
    static let hardwareKey = 0x71BA3
    static let pagersKey = 0x71B8F
    static let processCode = Data(fromHexString:
        "605a40f9610200b0218c2e9114baff971f0000f1e8079f1a683e0339" +
            "605a40f9610200b0213c2e910dbaff971f0000f1e8079f1a68420339")!
    static let stackCode = Data(fromHexString: "005840f9610200b0218c2e91ccb7ff97a00200b4")!
    static let cacheCode = Data(fromHexString: "c05a40f961020090213c2e9115b3ff971f0000f1e8079f1ae8470139")!
    static func store<T: FixedWidthInteger>(_ value: T, _ offset: Int, _ data: inout Data) {
        var little = value.littleEndian
        withUnsafeBytes(of: &little) { data.replaceSubrange(offset ..< offset + $0.count, with: $0) }
    }
    static func text(_ value: String, _ offset: Int, _ data: inout Data) {
        let bytes = Data((value + "\0").utf8)
        data.replaceSubrange(offset ..< offset + bytes.count, with: bytes)
    }
    static func image(platform: UInt32 = 3) -> Data {
        var data = Data(repeating: 0, count: 0x73000)
        store(UInt32(0xFEED_FACF), 0, &data)
        store(UInt32(0x0100_000C), 4, &data)
        store(UInt32(7), 12, &data)
        store(UInt32(3), 16, &data)
        store(UInt32(232 + 24 + 24), 20, &data)
        store(UInt32(0x19), 32, &data)
        store(UInt32(232), 36, &data)
        text("__TEXT", 40, &data)
        store(UInt64(0x72000), 64, &data)
        store(UInt64(0x72000), 80, &data)
        store(UInt32(5), 88, &data)
        store(UInt32(5), 92, &data)
        store(UInt32(2), 96, &data)
        text("__text", 104, &data)
        text("__TEXT", 120, &data)
        store(UInt64(0x1000), 136, &data)
        store(UInt64(0x26000), 144, &data)
        store(UInt32(0x1000), 152, &data)
        text("__cstring", 184, &data)
        text("__TEXT", 200, &data)
        store(UInt64(0x71000), 216, &data)
        store(UInt64(0x1000), 224, &data)
        store(UInt32(0x71000), 232, &data)
        store(UInt32(0x32), 264, &data)
        store(UInt32(24), 268, &data)
        store(platform, 272, &data)
        store(UInt32(2), 288, &data)
        store(UInt32(24), 292, &data)
        store(UInt32(0x72000), 296, &data)
        let symbols: [(String, Int)] = [
            (CustomFirmwareTVTPRO.process, processAddress),
            ("_process_end", processAddress + processCode.count),
            (CustomFirmwareTVTPRO.stack, stackAddress),
            ("_stack_end", stackAddress + stackCode.count),
            (CustomFirmwareTVTPRO.cacheConstructor, cacheAddress),
            ("_cache_end", cacheAddress + cacheCode.count),
            (CustomFirmwareTVTPRO.getenv, 0x12938),
        ]
        store(UInt32(symbols.count), 300, &data)
        store(UInt32(0x72200), 304, &data)
        var cursor = 1
        for (index, item) in symbols.enumerated() {
            let entry = 0x72000 + index * 16
            store(UInt32(cursor), entry, &data)
            data[entry + 4] = 0x0E
            data[entry + 5] = 1
            store(UInt64(item.1), entry + 8, &data)
            text(item.0, 0x72200 + cursor, &data)
            cursor += item.0.utf8.count + 1
        }
        store(UInt32(cursor), 308, &data)
        data.replaceSubrange(processAddress ..< processAddress + processCode.count, with: processCode)
        data.replaceSubrange(stackAddress ..< stackAddress + stackCode.count, with: stackCode)
        data.replaceSubrange(cacheAddress ..< cacheAddress + cacheCode.count, with: cacheCode)
        text("dyld_hw_tpro", hardwareKey, &data)
        text("dyld_hw_tpro_pagers", pagersKey, &data)
        return data
    }

    @Test func `only key prefixes change and repeated runs capture nothing`() throws {
        var data = Self.image()
        let original = data
        let dry = try CustomFirmwareTVTPRO.patchStandalone(&data, reattest: false, dryRun: true, log: nil)
        #expect(dry.outcome == .wouldPatch && dry.records.isEmpty && data == original)
        let patched = try CustomFirmwareTVTPRO.patchStandalone(&data, reattest: false, log: nil)
        #expect(patched.outcome == .patched && patched.records.count == 2)
        var expected = original
        for offset in [Self.hardwareKey, Self.pagersKey] {
            expected.replaceSubrange(offset ..< offset + 4, with: Data("vphn".utf8))
        }
        #expect(data == expected) // Includes all code, flags and load commands.
        #expect(patched.records.allSatisfy { $0.patchID.hasPrefix("system-dyld-exp-tv_tpro.standalone.") })
        let repeated = try CustomFirmwareTVTPRO.patchStandalone(&data, reattest: false, log: nil)
        #expect(repeated.outcome == .alreadyPatched && repeated.records.isEmpty && data == expected)
    }

    @Test func `a partial prior key edit only writes the remaining key`() throws {
        var data = Self.image()
        data.replaceSubrange(Self.hardwareKey ..< Self.hardwareKey + 4, with: Data("vphn".utf8))
        let report = try CustomFirmwareTVTPRO.patchStandalone(&data, reattest: false, log: nil)
        #expect(report.outcome == .patched && report.records.count == 1)
        #expect(report.records.first?.fileOffset == Self.pagersKey)
    }

    @Test func `platform malformed bounds and undefined symbols are refused atomically`() {
        var malformedCommands = Self.image()
        Self.store(UInt32.max, 20, &malformedCommands)
        var malformedSection = Self.image()
        Self.store(UInt64.max, 224, &malformedSection)
        var imported = Self.image()
        imported[0x72004] = 0
        for original in [Self.image(platform: 2), malformedCommands, malformedSection, imported, Data(Self.image().prefix(50))] {
            var data = original
            #expect(throws: (any Error).self) { try CustomFirmwareTVTPRO.patchStandalone(&data, reattest: false, log: nil) }
            #expect(data == original)
        }
    }

    @Test func `keys must be complete unique strings referenced by every relevant function`() throws {
        var missing = Self.image()
        missing[Self.hardwareKey] = Character("X").asciiValue!
        var duplicate = Self.image()
        Self.text("dyld_hw_tpro", 0x71100, &duplicate)
        var noReference = Self.image()
        noReference.replaceSubrange(Self.cacheAddress + 4 ..< Self.cacheAddress + 8, with: ARM64.nop)
        var wrongCall = Self.image()
        wrongCall.replaceSubrange(Self.stackAddress + 12 ..< Self.stackAddress + 16, with: ARM64.nop)
        var wrongPresence = Self.image()
        wrongPresence.replaceSubrange(Self.processAddress + 20 ..< Self.processAddress + 24,
                                      with: try #require(ARM64Encoder.encodeCsetW(rd: 8, condition: .eq)))
        for original in [missing, duplicate, noReference, wrongCall, wrongPresence] {
            var data = original
            #expect(throws: (any Error).self) { try CustomFirmwareTVTPRO.patchStandalone(&data, reattest: false, log: nil) }
            #expect(data == original)
        }
    }

    @Test func `unsigned input cannot leave either key modified`() {
        var data = Self.image()
        let original = data
        #expect(throws: (any Error).self) { try CustomFirmwareTVTPRO.patchStandalone(&data, log: nil) }
        #expect(data == original)
    }

    static var probeRoot: URL? {
        ProcessInfo.processInfo.environment["VPHONE_TV_TPRO_PROBE_ROOT"].map { URL(fileURLWithPath: $0) }
    }
    @Test(.enabled(if: probeRoot != nil))
    func `real dyld signature identity survives and both cache keys undo cleanly`() throws {
        let root = try #require(Self.probeRoot)
        var data = try Data(contentsOf: root.appendingPathComponent("dyld-tpro-probe"))
        let original = data
        let directories = try #require(CustomFirmwareMachOCodeSignature.codeDirectories(in: data))
        #expect(try CustomFirmwareTVTPRO.patchStandalone(&data, dryRun: true, log: nil).outcome == .wouldPatch)
        #expect(data == original)
        let changed = try CustomFirmwareTVTPRO.patchStandalone(&data, log: nil)
        #expect(changed.outcome == .patched && changed.records.count == 2)
        #expect(CustomFirmwareMachOCodeSignature.codeDirectories(in: data) == directories)
        for directory in directories {
            #expect(data[directory.offset ..< directory.offset + directory.hashOffset]
                == original[directory.offset ..< directory.offset + directory.hashOffset])
        }
        #expect(try CustomFirmwareMachOCodeSignature.reattest(&data, modifiedOffsets: changed.sites.map(\.fileOffset)).isEmpty)
        let attested = data
        #expect(try CustomFirmwareTVTPRO.patchStandalone(&data, log: nil).outcome == .alreadyPatched)
        #expect(data == attested)

        let directory = root.appendingPathComponent("tpro-cache-probe")
        let chunks = try DyldSharedCacheChunkSet(directory: directory, architecture: "arm64", captureUndo: true)
        #expect(try CustomFirmwareTVTPRO.patchCache(in: chunks, dryRun: true, log: nil).outcome == .wouldPatch)
        #expect(chunks.takeUndoLog()?.records.isEmpty == true)
        let changedCache = try CustomFirmwareTVTPRO.patchCache(in: chunks, log: nil)
        #expect(changedCache.outcome == .patched && changedCache.records.count == 2)
        var undo = try #require(chunks.takeUndoLog())
        undo.stamp(patchID: CustomFirmwareTVTPRO.patchID)
        #expect(!undo.records.isEmpty)
        let writes = chunks.recordedWrites.count
        #expect(try CustomFirmwareTVTPRO.patchCache(in: chunks, log: nil).outcome == .alreadyPatched)
        #expect(chunks.recordedWrites.count == writes && chunks.takeUndoLog()?.records.isEmpty == true)
        let spans = try undo.restore(patchIDs: [CustomFirmwareTVTPRO.patchID], in: directory)
        #expect(try DyldSharedCacheCodeSignature.reattest(in: chunks, modifiedSpans: spans, log: nil).isFullyAttested)
        for site in changedCache.sites {
            #expect(try chunks.bytesAtVMA(site.virtualAddress, length: 4) == site.originalBytes)
        }
        #expect(try CustomFirmwareTVTPRO.patchCache(in: chunks, dryRun: true, log: nil).outcome == .wouldPatch)
    }
}

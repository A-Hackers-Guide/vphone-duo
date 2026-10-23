@testable import FirmwarePatcher
import Foundation
import Testing
import VPhonePatchKit

struct KDKExportFixtureTests {
    static let base: UInt64 = 0xFFFF_FE00_0000_0000

    static func fixture() throws -> (KDKKernelCollection, KDKImage, [KDKSymbol], [KDKReference]) {
        let base = Self.base
        func section(_ segment: String, _ name: String, _ off: UInt32, _ size: UInt64, flags: UInt32 = 0, reserved: UInt32 = 0) -> KDKMachO.Section {
            .init(name: name, segmentName: segment, address: base + UInt64(off), size: size, offset: size == 0 ? 0 : off,
                  align: 3, relocationOffset: 0, relocationCount: 0, flags: flags, reserved1: reserved, reserved2: 0, reserved3: 0)
        }
        func segment(_ name: String, _ off: UInt64, _ size: UInt64, _ sections: [KDKMachO.Section] = []) -> [UInt8] {
            var bytes: [UInt8] = []
            KDKMachO.write(.init(command: KDKMachO.lcSegment64, commandSize: UInt32(72 + 80 * sections.count), name: name,
                                 address: base + off, memorySize: size, fileOffset: off, fileSize: size,
                                 maxProtection: 7, initialProtection: 3, sectionCount: UInt32(sections.count), flags: 0, sections: sections), to: &bytes)
            return bytes
        }
        func command(_ words: [UInt32]) -> [UInt8] {
            var bytes: [UInt8] = []
            for word in words {
                bytes.appendLE(word)
            }
            return bytes
        }
        func header(_ type: UInt32, _ loads: [[UInt8]]) -> [UInt8] {
            KDKMachO.Header(magic: KDKMachO.magic64, cpuType: 0x0100_000C, cpuSubtype: 2, fileType: type,
                            commandCount: UInt32(loads.count), commandsSize: UInt32(loads.flatMap(\.self).count),
                            flags: type == 0xC ? 0 : KDKMachO.mhDylibInCache, reserved: 0).bytes + loads.flatMap(\.self)
        }
        var entry = command([KDKMachO.lcFilesetEntry, 56])
        entry.appendLE(base + 0x1000)
        entry.appendLE(UInt64(0x1000))
        entry += command([32, 0])
        entry += Array("com.test.kext\0".utf8)
        entry.padTo(56)
        let imageLoads = [
            segment("__TEXT", 0x1000, 0x4000),
            segment("__TEXT_EXEC", 0x8000, 0x1000, [section("__TEXT_EXEC", "__text", 0x8100, 0x100), section("__TEXT_EXEC", "__auth_stubs", 0x9000, 0)]),
            segment("__DATA_CONST", 0xA000, 0x1000, [section("__DATA_CONST", "__auth_got", 0xA000, 16, flags: 6)]),
            segment("__LINKEDIT", 0xC000, 0x200),
            command([KDKMachO.lcSymtab, 24, 0xC000, 1, 0xC010, 16]),
            command([KDKMachO.lcDysymtab, 80, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0xC020, 2, 0, 0, 0, 0]),
            command([KDKMachO.lcFunctionStarts, 16, 0xC030, 8]),
        ]
        var bytes = [UInt8](repeating: 0, count: 0xD000)
        let top = header(0xC, [segment("__TEXT", 0, 0xD000), entry])
        bytes.replaceSubrange(0 ..< top.count, with: top)
        let image = header(0xB, imageLoads)
        bytes.replaceSubrange(0x1000 ..< 0x1000 + image.count, with: image)
        bytes.setLE(UInt32(1), at: 0xC000)
        bytes.replaceSubrange(0xC010 ..< 0xC020, with: [0] + Array("<redacted>\0".utf8) + [UInt8](repeating: 0, count: 4))
        let ext: UInt64 = 0xFFFF_FE00_0002_0000
        bytes.setLE(UInt64(0x8000_1234_0002_0000), at: 0xA000)
        bytes.setLE(UInt64(0x8000_5678_0000_8100), at: 0xA008)
        let branch = try #require(ARM64Encoder.encodeBL(from: 0x8100, to: 0x20000))
        bytes.replaceSubrange(0x8100 ..< 0x8104, with: branch)
        try bytes.replaceSubrange(0x8104 ..< 0x8108, with: #require(ARM64Encoder.encodeADRP(rd: 8, pc: base + 0x8104, target: base + 0xA000)))
        try bytes.replaceSubrange(0x8108 ..< 0x810C, with: #require(ARM64Encoder.encodeAddImm12(rd: 8, rn: 8, imm12: 0)))
        var starts: [UInt8] = []
        starts.appendULEB128(0x7100)
        starts.append(0)
        starts.pad(to: 8)
        bytes.replaceSubrange(0xC030 ..< 0xC038, with: starts)
        let collection = try KDKKernelCollection(Data(bytes))
        let symbols: [KDKSymbol] = [.init(name: "_entry", type: 0xE, sect: 1, desc: 0, value: base + 0x8100),
                                    .init(name: "_external", type: 1, sect: 0, desc: 0, value: ext)]
        let refs: [KDKReference] = [.init(kind: 7, source: base + 0x8100, target: ext),
                                    .init(kind: 5, source: base + 0x8104, target: base + 0xA000),
                                    .init(kind: 6, source: base + 0x8108, target: base + 0xA000, extra: base + 0x8104),
                                    .init(kind: 2, source: base + 0xA000, target: ext),
                                    .init(kind: 2, source: base + 0xA008, target: base + 0x8100)]
        return try (collection, collection.image("com.test.kext"), symbols, refs)
    }

    @Test func packedExportRestoresStandaloneReferences() throws {
        var (collection, image, symbols, refs) = try Self.fixture()
        // A stripped indirect table has no trustworthy symbol identity.
        image.symbols = []
        var writer = try KDKImageExport(collection: collection, image: image, baseAddress: 0, symbols: symbols, references: refs, addressOnlyBinds: true)
        let output = try writer.export()
        let (header, commands) = try KDKMachO.loadCommands(in: .init(data: output), at: 0)
        #expect(header.flags & KDKMachO.mhDylibInCache == 0)
        #expect(header.commandCount == image.header.commandCount + 2)
        #expect(commands[4].command == KDKMachO.lcDyldChainedFixups)
        #expect(commands[commands.count - 2].command == KDKMachO.lcSegmentSplitInfo)
        let bytes = [UInt8](output)
        #expect(ARM64Encoder.decodeBranchTarget(insn: bytes.le(UInt32.self, 0x4100), pc: 0x4100) == 0x5000)
        #expect(bytes.le(UInt32.self, 0x500C) == 0xD71F_0A11)
        #expect(bytes.le(UInt64.self, 0x8000) == 0xC010_1234_0000_0000) // auth bind, next = 2
        #expect(bytes.le(UInt64.self, 0x8008) == 0x8000_5678_0000_4100) // auth rebase
        let sym = try #require(commands.first { $0.command == KDKMachO.lcSymtab })
        let syms = try KDKMachO.symbols(sym.bytes, in: .init(data: output))
        #expect(syms.map(\.name) == ["_entry", "_external"])
        #expect(syms.map(\.value) == [0x4100, 0])
        let dysym = try #require(commands.first { $0.command == KDKMachO.lcDysymtab })
        #expect(try KDKMachO.indirectSymbols(dysym.bytes, in: .init(data: output)) == [1, KDKMachO.indirectSymbolLocal])
        let function = try #require(commands.first { $0.command == KDKMachO.lcFunctionStarts })
        let start = Int(function.bytes.le(UInt32.self, 8))
        #expect(Array(bytes[start ..< start + 4]) == [0x80, 0x82, 1, 0])
        let linkedit = try #require(commands.compactMap(\.segment).first { $0.name == "__LINKEDIT" })
        #expect(UInt64(output.count) == linkedit.fileOffset + linkedit.fileSize)
        #expect(try writer.export() == output)
        // Repeat from the same immutable input, in a different reference order.
        refs.reverse()
        var second = try KDKImageExport(collection: collection, image: image, baseAddress: 0, symbols: symbols, references: refs, addressOnlyBinds: true)
        #expect(try second.export() == output)
    }

    @Test func cacheAddressExportKeepsVMAddresses() throws {
        let (collection, image, symbols, _) = try Self.fixture()
        var writer = try KDKImageExport(collection: collection, image: image, baseAddress: 0, symbols: symbols, references: [], addressOnlyBinds: true)
        let output = try writer.export()
        let (_, commands) = try KDKMachO.loadCommands(in: .init(data: output), at: 0)
        #expect(commands.compactMap(\.segment).map(\.address) == image.segments.map(\.address))
        #expect(!commands.contains { $0.command == KDKMachO.lcDyldChainedFixups })
    }

    @Test func malformedCommandsThrowInsteadOfTrapping() throws {
        let (collection, _, _, _) = try Self.fixture()
        var data = [UInt8](collection.bytes.data)
        data.setLE(UInt32.max, at: 36)
        #expect(throws: PatcherError.self) { try KDKKernelCollection(Data(data)) }
        data = [UInt8](collection.bytes.data)
        data.setLE(UInt32.max, at: 16)
        #expect(throws: PatcherError.self) { try KDKKernelCollection(Data(data)) }
    }
}

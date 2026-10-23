@testable import FirmwarePatcher
import Foundation
import Testing
import VPhonePatchKit

struct KDKImageExportTests {
    @Test func pointerLayouts() throws {
        #expect(try KDKImageExport.pointer(target: 0xFE00_0000_0123_4567, ordinal: nil, auth: nil, next: 3) == 0x001F_F000_0123_4567)
        #expect(try KDKImageExport.pointer(target: 0, ordinal: 7, addend: -4, auth: nil, next: 2) == 0x4017_FFFC_0000_0007)
        #expect(try KDKImageExport.pointer(target: 0x4000, ordinal: nil, auth: 0x0005_1234_0000_0000, next: 5) == 0x802D_1234_0000_4000)
        #expect(try KDKImageExport.pointer(target: 0, ordinal: 9, auth: 0x0002_BEEF_0000_0000, next: 1) == 0xC00A_BEEF_0000_0009)
        #expect(throws: PatcherError.self) { try KDKImageExport.pointer(target: 0, ordinal: 0, addend: 1 << 18, auth: nil, next: 0) }
        #expect(throws: PatcherError.self) { try KDKImageExport.pointer(target: 0, ordinal: nil, auth: nil, next: 0x800) }
    }

    @Test func braaAndKernelADRP() throws {
        // xcrun clang -arch arm64e (2026-10-23), verified independently of
        // this encoder. Keystone 0.9.2 rejects BRAA; it cannot be the oracle.
        let cases: [(UInt32, UInt32, UInt32)] = [(16, 17, 0xD71F_0A11), (0, 1, 0xD71F_0801), (30, 31, 0xD71F_0BDF)]
        for (rn, rm, expected) in cases {
            let encoded = try #require(ARM64Encoder.encodeBRAA(rn: rn, rm: rm))
            #expect([UInt8](encoded).le(UInt32.self, 0) == expected)
            let decoded = try #require(ARM64Disassembler().disassembleOne(encoded, at: 0))
            #expect(decoded.mnemonic == "braa")
        }
        #expect(ARM64Encoder.encodeBRAA(rn: 31, rm: 0) == nil)
        #expect(ARM64Encoder.encodeBRAA(rn: 0, rm: 32) == nil)
        let low = ARM64Encoder.encodeADRP(rd: 17, pc: 0x4000, target: 0xA123)
        let high = ARM64Encoder.encodeADRP(rd: 17, pc: 0xFFFF_FE00_0000_4000, target: 0xFFFF_FE00_0000_A123)
        #expect(low == high)
        #expect(high != nil)
    }

    @Test func off12RetainsInstructionAndScale() throws {
        // Independent clang encodings of ldr/str/ldrsw/ldr q/add (see guide).
        let cases: [(UInt32, UInt32, UInt32)] = [
            (0x3940_0020, 0x123, 0x3944_8C20), // ldrb w0, [x1, #0x123]
            (0x7940_0020, 0x246, 0x7944_8C20), // ldrh
            (0xB940_0020, 0x48C, 0xB944_8C20), // ldr w0
            (0xF940_0020, 0x918, 0xF944_8C20), // ldr x0
            (0x3DC0_0020, 0x230, 0x3DC0_8C20), // ldr q0
            (0x9100_0020, 0x123, 0x9104_8C20), // add x0, x1
        ]
        for (word, offset, expected) in cases {
            let encoded = try #require(ARM64Encoder.retargetPageOffset(word, offset: offset))
            let actual = [UInt8](encoded).le(UInt32.self, 0)
            #expect(actual == expected)
            #expect(ARM64Encoder.decodePageOffset(actual) == offset)
            #expect(ARM64Disassembler().disassembleOne(encoded, at: 0) != nil)
        }
        #expect(ARM64Encoder.retargetPageOffset(0xD503_201F, offset: 4) == nil)
    }

    /// Opt-in external corpus: no Apple firmware or extracted binaries checked
    /// in. Xcode passes TEST_RUNNER_KDK_PARITY_ROOT to the test process as
    /// KDK_PARITY_ROOT. Each JSON is the reference Export call's complete input.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["KDK_PARITY_ROOT"] != nil))
    func referenceCorpusByteParity() throws {
        let root = try URL(fileURLWithPath: #require(ProcessInfo.processInfo.environment["KDK_PARITY_ROOT"]))
        let selected = ProcessInfo.processInfo.environment["KDK_PARITY_ENTRY"]
        let fm = FileManager.default
        struct Symbol: Decodable {
            var name: String
            var indirectName: String?
            var type: UInt8
            var sect: UInt8
            var desc: UInt16
            var value: UInt64
            var valueModel: KDKSymbol {
                .init(name: name, indirectName: indirectName ?? "", type: type, sect: sect, desc: desc, value: value)
            }
        }
        struct Input: Decodable {
            var entryID: String
            var output: String
            var baseAddress: UInt64
            var addressOnlyBinds: Bool
            var symbols: [Symbol]
            var references: [KDKReference]
        }
        var verified = 0
        for (label, kernel) in [("donor", "vphone600"), ("research", "vresearch101")] {
            let collectionURL = root.appending(path: "data/264beta/kernelcache.release.\(kernel).decompressed")
            let collection = try KDKKernelCollection(Data(contentsOf: collectionURL, options: .mappedIfSafe))
            let corpus = root.appending(path: "parity/\(label)")
            let files = try fm.contentsOfDirectory(at: corpus.appending(path: "inputs"), includingPropertiesForKeys: nil)
                .filter { $0.pathExtension == "json" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
            #expect(files.count == collection.entries.count)
            for file in files {
                let input = try JSONDecoder().decode(Input.self, from: Data(contentsOf: file))
                if let selected, selected != input.entryID {
                    continue
                }
                var image = try collection.image(input.entryID)
                // extract.go performs this before calling Export; the dump hook
                // intentionally captures Export arguments, not this preparation.
                if input.entryID == "com.apple.kernel", let thread = collection.unixThread,
                   let i = image.commands.firstIndex(where: { $0.command == KDKMachO.lcUnixThread })
                {
                    image.commands[i] = thread
                }
                var writer = try KDKImageExport(collection: collection, image: image, baseAddress: input.baseAddress,
                                                symbols: input.symbols.map(\.valueModel), references: input.references,
                                                addressOnlyBinds: input.addressOnlyBinds)
                let actual = try writer.export()
                let expected = try Data(contentsOf: corpus.appending(path: "out").appending(path: input.output))
                if actual != expected {
                    let difference = zip(actual, expected).enumerated().first { $0.element.0 != $0.element.1 }?.offset ?? min(actual.count, expected.count)
                    let destination = root.appending(path: "swift-\(label)-\(input.entryID)")
                    try actual.write(to: destination)
                    Issue.record("\(label)/\(input.entryID): first difference 0x\(String(difference, radix: 16)), Swift \(actual.count) vs Go \(expected.count) bytes; wrote \(destination.path)")
                    return
                }
                verified += 1
                if verified % 20 == 0 {
                    print("KDK parity: \(verified) images verified")
                }
            }
        }
        #expect(verified == (selected == nil ? 264 : 2))
        print("KDK parity: all \(verified) exports are byte-identical")
    }
}

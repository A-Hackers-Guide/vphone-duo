@testable import FirmwarePatcher
import Darwin
import Foundation
import Testing
import VPhonePatchKit

@_silgen_name("sys_icache_invalidate")
private func invalidateKernelCSSCTestCode(_ memory: UnsafeMutableRawPointer, _ count: Int)

@Suite("Kernel CSSC compatibility")
struct KernelCSSCTests {
    @Test func `new encoders match Keystone 0_9_2`() throws {
        let cases: [(Data?, UInt32)] = [
            (ARM64Encoder.encodeBitfieldExtract(rd: 3, rn: 4, lsb: 5, width: 6), 0xD3452883),
            (ARM64Encoder.encodeBitfieldExtract(rd: 3, rn: 4, lsb: 0, width: 32, signed: true), 0x93407C83),
            (ARM64Encoder.encodeAndRegister(rd: 3, rn: 0, rm: 12, width64: false), 0x0A0C0003),
            (ARM64Encoder.encodeAndRegister(rd: 3, rn: 4, rm: 5), 0x8A050083),
            (ARM64Encoder.encodeCompareRegister(rn: 3, rm: 4), 0xEB04007F),
            (ARM64Encoder.encodeConditionalSelect(rd: 3, rn: 4, rm: 5, condition: .ge), 0x9A85A083),
            (ARM64Encoder.encodeReverseBits(rd: 3, rn: 4, width64: false), 0x5AC00083),
            (ARM64Encoder.encodeReverseBits(rd: 3, rn: 4, width64: true), 0xDAC00083),
            (ARM64Encoder.encodeCountLeadingZeros(rd: 3, rn: 4, width64: false), 0x5AC01083),
            (ARM64Encoder.encodeCountLeadingZeros(rd: 3, rn: 4, width64: true), 0xDAC01083),
            (ARM64Encoder.encodeReadStatus(rt: 16), 0xD53B4210),
            (ARM64Encoder.encodeWriteStatus(rt: 16), 0xD51B4210),
            (ARM64Encoder.encodeSelectStackPointer(interruptStack: true), 0xD50041BF),
            (ARM64Encoder.encodeSelectStackPointer(interruptStack: false), 0xD50040BF),
        ]
        for (data, expected) in cases {
            let bytes = try #require(data)
            #expect(bytes.loadLE(UInt32.self, at: 0) == expected)
        }
        #expect(ARM64Encoder.encodeBitfieldExtract(rd: 0, rn: 0, lsb: 63, width: 2) == nil)
        #expect(ARM64Encoder.encodeBitfieldExtract(rd: 0, rn: 0, lsb: 0, width: 0) == nil)
        #expect(ARM64Encoder.encodeReverseBits(rd: 32, rn: 0, width64: true) == nil)
    }

    #if arch(arm64)
    @Test func `baseline emulator executes all scalar forms without modifying input registers`() throws {
        let code = try VPhoneCSSCCode.emulator()
        #expect(code.count < 4096)
        let decoded = ARM64Disassembler().disassemble(code)
        #expect(decoded.allSatisfy { $0.isDecoded })
        #expect(!decoded.contains(where: { ["abs", "ctz", "cnt", "smax", "smin", "umax", "umin", "mrs", "msr"].contains($0.mnemonic) }))
        let memory = try #require(mmap(nil, 0x4000, PROT_READ | PROT_WRITE, MAP_ANON | MAP_PRIVATE, -1, 0))
        try #require(memory != MAP_FAILED)
        defer { munmap(memory, 0x4000) }
        code.copyBytes(to: memory.assumingMemoryBound(to: UInt8.self), count: code.count)
        try #require(mprotect(memory, 0x4000, PROT_READ | PROT_EXEC) == 0)
        invalidateKernelCSSCTestCode(memory, code.count)
        typealias Function = @convention(c) (UInt32, UnsafePointer<UInt64>, UnsafeMutablePointer<UInt64>) -> UInt64
        let function = unsafeBitCast(memory, to: Function.self)
        var registers = (0..<31).map { UInt64($0) &* 0xFEDC_BA98_7654_3211 }
        let values: [UInt64] = [0, 1, 7, 0x8000_0000, 0xFFFF_FFFF, 1 << 63, .max, .max - 6]
        for wide in [false, true] {
            let sf: UInt32 = wide ? 0x8000_0000 : 0
            let mask: UInt64 = wide ? .max : UInt64(UInt32.max)
            let sign: UInt64 = wide ? 1 << 63 : 1 << 31
            for rn: UInt32 in [0, 16, 17, 29, 30, 31] {
                for value in values {
                    if rn < 31 { registers[Int(rn)] = value }
                    let a = rn == 31 ? 0 : value & mask
                    let unary: [(UInt32, UInt64)] = [
                        (0x5AC02000, a & sign == 0 ? a : (0 &- a) & mask),
                        (0x5AC01C00, UInt64(a.nonzeroBitCount)),
                        (0x5AC01800, a == 0 ? (wide ? 64 : 32) : UInt64(a.trailingZeroBitCount)),
                    ]
                    for (opcode, expected) in unary {
                        for rd: UInt32 in [0, 16, 17, 29, 30, 31, rn] {
                            var result = UInt64.max
                            let before = registers
                            #expect(registers.withUnsafeBufferPointer { function(sf | opcode | rn << 5 | rd, $0.baseAddress!, &result) } == 1)
                            #expect(result == expected)
                            #expect(registers == before)
                        }
                    }
                    for kind: UInt32 in 0..<4 {
                        for immediate in [false, true] {
                            for operand in [UInt64(0), 1, 127, 128, 255, .max] {
                                let rm: UInt32 = 18
                                registers[Int(rm)] = operand
                                let opcode: UInt32 = immediate ? 0x11C00000 + kind * 0x40000 : 0x1AC06000 + kind * 0x400
                                let encoded = immediate ? UInt32(operand & 255) << 10 : rm << 16
                                var b = immediate ? operand & 255 : operand & mask
                                let signed = kind & 1 == 0
                                if immediate && signed && b & 128 != 0 { b |= .max << 8 }
                                b &= mask
                                let flip = signed ? sign : 0
                                let expected = ((a ^ flip) < (b ^ flip)) == (kind & 2 != 0) ? a : b
                                var result: UInt64 = 0
                                #expect(registers.withUnsafeBufferPointer { function(sf | opcode | encoded | rn << 5 | rn, $0.baseAddress!, &result) } == 1)
                                #expect(result == expected)
                            }
                        }
                    }
                }
            }
        }
        for word: UInt32 in [0, 0xD503201F, 0xDAC1A7FE, 0x4E205800, .max] {
            var result: UInt64 = 0xAABBCCDD
            let before = registers
            #expect(registers.withUnsafeBufferPointer { function(word, $0.baseAddress!, &result) } == 0)
            #expect(result == 0xAABBCCDD)
            #expect(registers == before)
        }
    }
    #endif

    @Test func `gate is narrow and presets retain their exclusions`() throws {
        for (base, cloud, expected) in [("27.1", "26.4", true), ("26.7", "26.4", false), ("27.1", "26.5", false)] {
            let plan = try VPhonePatchPlan.resolve(preset: FirmwarePatchSetCatalog.standardPreset,
                patchSets: FirmwarePatchSetCatalog.bundled, iOSBase: VPhoneVersion(base), cloudOS: VPhoneVersion(cloud))
            #expect(plan.isEnabled(FirmwareKernelCustomFirmwarePatchSet.cssc) == expected)
        }
        let patcher = KernelCustomFirmwarePatcher(data: Data(repeating: 0, count: 256), verbose: false)
        #expect(throws: (any Error).self) { try patcher.patchCSSC() }
        #expect(patcher.patches.isEmpty)
        #expect(patcher.patchedData == patcher.buffer.original)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["VPHONE_CSSC_KERNEL"] != nil))
    func `real research kernel reveals the complete handler before writing`() throws {
        let path = try #require(ProcessInfo.processInfo.environment["VPHONE_CSSC_KERNEL"])
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        let patcher = KernelCustomFirmwarePatcher(data: data, verbose: true)
        patcher.parseMachO()
        patcher.buildADRPIndex()
        let h = try #require(patcher.revealCSSCHandler())
        print("CSSC reveal hook=\(String(h.hook, radix: 16)) check=\(String(h.check, radix: 16)) sign=\(String(h.sign, radix: 16))")
        try patcher.patchCSSC()
        #expect(patcher.patches.count == 2)
        let payload = try #require(patcher.patches.first)
        #expect(payload.patchedBytes.count < 4096)
        let code = ARM64Disassembler().disassemble(payload.patchedBytes, at: UInt64(payload.fileOffset))
        var protected = false
        for instruction in code {
            if instruction.mnemonic == "msr", instruction.operandString.lowercased().hasPrefix("spsel,") {
                protected = instruction.detail?.operands.last?.imm == 1
            }
            if protected {
                #expect(!(instruction.detail?.operands.contains(where: { $0.type == .memory && $0.mem.base == .sp }) ?? false))
            }
        }
        #expect(!protected)
        // Unrecognized layouts fail before any mutation, rather than guessing.
        var changed = data
        changed.replaceSubrange(h.check..<h.check + 160, with: Data(repeating: 0, count: 160))
        let invalid = KernelCustomFirmwarePatcher(data: changed, verbose: false)
        invalid.parseMachO()
        invalid.buildADRPIndex()
        #expect(throws: (any Error).self) { try invalid.patchCSSC() }
        #expect(invalid.patchedData == changed)
        #expect(invalid.patches.isEmpty)
    }
}

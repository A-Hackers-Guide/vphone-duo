@testable import FirmwarePatcher
import Foundation
import Testing
import VPhonePatchKit

struct KDKRecoveryFlowTests {
    func code(_ instructions: [UInt64: Data], functions: [KDKFunction]) -> KDKRecovery.FlowContext {
        var bytes = [UInt8](repeating: 0, count: 0x200)
        for (pc, data) in instructions {
            bytes.replaceSubrange(Int(pc - 0x1000) ..< Int(pc - 0x1000) + data.count, with: data)
        }
        let section = KDKMachO.Section(name: "__text", segmentName: "__TEXT_EXEC", address: 0x1000, size: 0x200,
                                       offset: 0, align: 2, relocationOffset: 0, relocationCount: 0, flags: 0x8000_0400,
                                       reserved1: 0, reserved2: 0, reserved3: 0)
        return .init(code: .init(section: section, bytes: bytes), functions: functions, symbols: [])
    }

    func recovery() throws -> KDKRecovery {
        try KDKRecovery(KDKExportFixtureTests.fixture().0)
    }

    func track(_ recovery: KDKRecovery, _ context: KDKRecovery.FlowContext, start: UInt64, register: UInt32) -> [UInt64: UInt64] {
        var returns: [UInt64: Bool] = [:], visited: [UInt64: Set<UInt32>] = [:]
        return recovery.track(context, at: start, register: register, target: 0x8000, returns: &returns, visited: &visited)
    }

    @Test func `outlined callee clobber stops tracking`() throws {
        let recovery = try recovery()
        let functions = [KDKFunction(start: 0x1000, end: 0x1010), KDKFunction(start: 0x1100, end: 0x1110)]
        var instructions: [UInt64: Data] = try [
            0x1004: #require(ARM64Encoder.encodeBL(from: 0x1004, to: 0x1100)),
            0x1008: #require(ARM64Encoder.encodeLdrXUnsignedOffset(rt: 0, rn: 19, offset: 0x20)),
            0x100C: ARM64.ret, 0x1100: ARM64.ret,
        ]
        #expect(track(recovery, code(instructions, functions: functions), start: 0x1004, register: 19)[0x1008] == 0x8020)
        instructions[0x1100] = try #require(ARM64Encoder.encodeADRP(rd: 19, pc: 0x1100, target: 0x9000))
        instructions[0x1104] = ARM64.ret
        #expect(track(recovery, code(instructions, functions: functions), start: 0x1004, register: 19).isEmpty)
    }

    @Test func `outlined ADRP hands register back to caller`() throws {
        let recovery = try recovery()
        let context = try code([
            0x1000: #require(ARM64Encoder.encodeBL(from: 0x1000, to: 0x1100)),
            0x1004: #require(ARM64Encoder.encodeLdrXUnsignedOffset(rt: 0, rn: 24, offset: 0x28)),
            0x1008: ARM64.ret,
            0x1100: #require(ARM64Encoder.encodeADRP(rd: 24, pc: 0x1100, target: 0x8000)),
            0x1104: ARM64.ret,
        ], functions: [.init(start: 0x1000, end: 0x1010), .init(start: 0x1100, end: 0x1110)])
        context.adrpFunction = 0x1100
        #expect(track(recovery, context, start: 0x1104, register: 24)[0x1004] == 0x8028)
        #expect(context.viaReturn.contains(0x1004))
    }

    @Test func `foreign non returning loop ends dataflow`() throws {
        let recovery = try recovery()
        let foreignContext = try code([0x1100: #require(ARM64Encoder.encodeB(from: 0x1100, to: 0x1100))], functions: [.init(start: 0x1100, end: 0x1104)])
        recovery.allCode = [foreignContext.code]
        recovery.allCodeStarts = [0x1000]
        recovery.allFunctions = [.init(start: 0x1100, end: 0x1104)]
        recovery.allFunctionStarts = [0x1100]
        #expect(!recovery.foreignMayReturn(0x1100, depth: 0))
    }

    @Test func `instruction predicates agree with capstone`() throws {
        let encodings = [
            ARM64Encoder.encodeADRP(rd: 19, pc: 0x1000, target: 0x8000),
            ARM64Encoder.encodeAddImm12(rd: 20, rn: 19, imm12: 0x28),
            ARM64Encoder.encodeLdrXUnsignedOffset(rt: 0, rn: 19, offset: 0x20),
            ARM64Encoder.encodeLdrWUnsignedOffset(rt: 1, rn: 19, offset: 4),
            ARM64Encoder.encodeStrXUnsignedOffset(rt: 20, rn: 19, offset: 8),
            ARM64Encoder.encodeStpX(rt1: 19, rt2: 20, rn: 31, offset: 16),
            ARM64Encoder.encodeCmpWImmediate(rn: 0, imm12: 1),
        ]
        let decoder = ARM64Disassembler()
        for data in encodings {
            let data = try #require(data)
            let word = [UInt8](data).le(UInt32.self, 0)
            let instruction = try #require(decoder.disassembleOne(data, at: 0x1000))
            for register in 0 ..< 31 {
                let decodedWrite = instruction.detail?.operands.contains {
                    $0.type == .register && $0.writesRegister && ($0.reg == .x(register) || $0.reg == .w(register))
                } ?? false
                #expect(KDKInstruction.writes(word, UInt32(register)) == decodedWrite, "\(instruction.mnemonic), x\(register)")
            }
        }
        for data in [ARM64Encoder.encodeB(from: 0x1000, to: 0x800), ARM64Encoder.encodeBL(from: 0x1000, to: 0x2000),
                     ARM64Encoder.encodeCompareBranch(nonzero: true, register: 1, from: 0x1000, to: 0x1080),
                     ARM64Encoder.encodeTestBitBranch(nonzero: false, register: 2, bit: 40, from: 0x1000, to: 0xFC0)]
        {
            let data = try #require(data)
            let decoded = try #require(decoder.disassembleOne(data, at: 0x1000))
            let target = try #require(decoded.detail?.operands.last(where: { $0.type == .immediate })?.imm)
            #expect(KDKInstruction.branch([UInt8](data).le(UInt32.self, 0), 0x1000) == UInt64(bitPattern: target))
        }
    }
}

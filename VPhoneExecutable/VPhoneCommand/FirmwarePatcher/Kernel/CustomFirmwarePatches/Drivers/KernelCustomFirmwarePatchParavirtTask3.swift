// KernelCustomFirmwarePatchParavirtTask3.swift — CFW kernel patch: ask the host
// for paravirtual GPU binary version 252 while the guest keeps the features of
// the version it was built for.
//
// Background: the guest GPU kext (AppleParavirtGPUIOGPUFamily) negotiates a
// binary version with ParavirtualizedGraphics at start-up, and the host derives
// its APVFeatures from it (`getAPVFeaturesForVersion`), a ladder where newer
// versions add flags. The cloudOS 26.4 kext asks for 245. 250 adds
// supportsDisplayBrightnessCaps, 251 supportsHDRContentHeadroom and 252
// supportsTask3, which makes `-[PGRemoteTask calculateCachePathAndExtension:
// taskRoot:]` name a task's host shader cache after 20 guest bytes (task root
// page, offset 0x28) when they are not all zero, instead of 10 random bytes.
// Host-side, the 250 flag is read only by a brightness test hook and the 251
// flag by nothing. See Research/Guest/gpu_acceleration.md.
//
// The kext's `setupVersion` path:
//
//     mov  wR, #<version>          ; the version this kext was built for
//     str  wR, [xSelf, #ivar]
//     ldr  xRegs, [xSelf, #regs]
//     str  wR, [xRegs, #reg]       ; request
//     ...
//     ldr  wV, [xRegs, #reg]       ; what the host granted
//     ...
//     mov  x0, xV                  ; guest-side features for that version
//     bl   <guest getAPVFeaturesForVersion>
//
// The guest's own table stops at the version it was built for, so a granted 252
// would come back invalid and the kext would step down again. The patch asks for
// 252 and computes the guest's features from the original immediate, so the
// guest keeps its behaviour while the host runs its Task3 path.
//
// Anchor (no offsets): the `setupVersion` cstring, whose references all sit in
// that one function; inside it, the request store and the readback of the same
// register displacement, and the granted version passed to the next call.

import Foundation
import VPhonePatchKit

extension KernelCustomFirmwarePatcher {
    /// The binary version whose host features include supportsTask3.
    private static let paravirtTask3Version: UInt16 = 252

    @discardableResult
    func patchParavirtTask3Version() -> Bool {
        log("\n[CFW]AppleParavirtGPU binary version: request \(Self.paravirtTask3Version), keep the guest's own features")

        guard let (ks, ke) = kernTextRange else {
            log("  [-] no kernel text range")
            return false
        }
        guard let nameOff = buffer.findString("setupVersion") else {
            log("  [-] setupVersion cstring not found")
            return false
        }
        let refs = findStringRefs(nameOff, in: (ks, ke))
        let starts = Set(refs.compactMap { findFunctionStart($0.adrpOff) })
        guard starts.count == 1, let funcStart = starts.first,
              let lastRef = refs.map(\.adrpOff).max()
        else {
            log("  [-] setupVersion not resolved to one function (found \(starts.count))")
            return false
        }

        var hits: [(request: Int, rd: UInt32, version: UInt16, featureArg: Int)] = []
        var off = funcStart
        while off < lastRef {
            defer { off += 4 }
            guard let (rd, version) = plainMoveW(at: off),
                  version >= 200, version < Self.paravirtTask3Version,
                  let regDisp = requestStore(of: rd, after: off),
                  let granted = readback(disp: regDisp, after: off),
                  let featureArg = versionArgument(granted.register, after: granted.offset)
            else { continue }
            hits.append((off, rd, version, featureArg))
        }

        guard hits.count == 1, let hit = hits.first else {
            log("  [-] version request not found uniquely (found \(hits.count))")
            return false
        }
        guard let request = ARM64Encoder.encodeMovzW(rd: hit.rd, imm16: Self.paravirtTask3Version),
              let guestVersion = ARM64Encoder.encodeMovzW(rd: 0, imm16: hit.version)
        else {
            log("  [-] could not encode the version constants")
            return false
        }

        emit(
            hit.request,
            request,
            patchID: FirmwarePatchSetCatalog.paravirtTask3Patch + ".request",
            virtualAddress: fileOffsetToVA(hit.request),
            description: "binary version request mov w\(hit.rd),#\(hit.version) -> #\(Self.paravirtTask3Version)",
        )
        emit(
            hit.featureArg,
            guestVersion,
            patchID: FirmwarePatchSetCatalog.paravirtTask3Patch + ".features",
            virtualAddress: fileOffsetToVA(hit.featureArg),
            description: "guest features from the granted version -> mov w0,#\(hit.version)",
        )
        return true
    }

    /// The register number and value when the instruction at `off` is a lone
    /// `mov wN, #imm` (no `movk` after it).
    private func plainMoveW(at off: Int) -> (UInt32, UInt16)? {
        guard let insn = disasAt(off), insn.mnemonic == "mov",
              let ops = insn.detail?.operands, ops.count == 2,
              ops[0].type == .register, ops[1].type == .immediate,
              (0 ... 0xFFFF).contains(ops[1].imm),
              let rd = (0 ... 30).first(where: { ARM64Register.w($0) == ops[0].reg }),
              disasAt(off + 4)?.mnemonic != "movk"
        else { return nil }
        return (UInt32(rd), UInt16(ops[1].imm))
    }

    /// The displacement of the register store `str wN, [xB, #disp]` that follows
    /// within four instructions, where `xB` was just loaded from memory: the
    /// version request written to the device.
    private func requestStore(of rd: UInt32, after off: Int) -> Int32? {
        let reg = ARM64Register.w(Int(rd))
        var loadedBases: Set<ARM64Register> = []
        for delta in stride(from: 4, through: 16, by: 4) {
            guard let insn = disasAt(off + delta), let ops = insn.detail?.operands else { return nil }
            if insn.mnemonic == "ldr", ops.count == 2, ops[0].type == .register, ops[1].type == .memory {
                loadedBases.insert(ops[0].reg)
            }
            if insn.mnemonic == "str", ops.count == 2, ops[0].type == .register, ops[0].reg == reg,
               ops[1].type == .memory, ops[1].mem.index == .invalid, loadedBases.contains(ops[1].mem.base)
            {
                return ops[1].mem.disp
            }
            if insn.isJump || insn.isCall || insn.isReturn { return nil }
        }
        return nil
    }

    /// The 32-bit load of the same device register within the next 12
    /// instructions: what the host granted.
    private func readback(disp: Int32, after off: Int) -> (register: ARM64Register, offset: Int)? {
        for delta in stride(from: 8, through: 48, by: 4) {
            guard let insn = disasAt(off + delta), let ops = insn.detail?.operands else { return nil }
            if insn.mnemonic == "ldr", ops.count == 2, ops[0].type == .register,
               (0 ... 30).contains(where: { ARM64Register.w($0) == ops[0].reg }),
               ops[1].type == .memory, ops[1].mem.index == .invalid, ops[1].mem.disp == disp
            {
                return (ops[0].reg, off + delta)
            }
            if insn.isReturn || insn.mnemonic == "b" || insn.mnemonic == "br" { return nil }
        }
        return nil
    }

    /// The `mov x0, xV` immediately before a `bl`, within the next 16
    /// instructions, passing the granted version on.
    private func versionArgument(_ granted: ARM64Register, after off: Int) -> Int? {
        guard let number = (0 ... 30).first(where: { ARM64Register.w($0) == granted }) else { return nil }
        let wide = ARM64Register.x(number)
        for delta in stride(from: 4, through: 64, by: 4) {
            guard let insn = disasAt(off + delta), let ops = insn.detail?.operands else { return nil }
            if insn.mnemonic == "mov", ops.count == 2,
               ops[0].type == .register, ops[0].reg == .x(0),
               ops[1].type == .register, ops[1].reg == wide,
               disasAt(off + delta + 4)?.mnemonic == "bl"
            {
                return off + delta
            }
            if insn.isReturn || insn.mnemonic == "b" || insn.mnemonic == "br" { return nil }
        }
        return nil
    }
}

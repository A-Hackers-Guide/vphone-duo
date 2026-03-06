"""Mixin: KernelJBPatchVmProtectMixin."""

from capstone.arm64_const import ARM64_REG_WZR

from .kernel_jb_base import ARM64_OP_IMM, ARM64_OP_REG


class KernelJBPatchVmProtectMixin:
    def patch_vm_map_protect(self):
        """Skip the vm_map_protect write-downgrade gate.

        Source-backed anchor: recover the function from the in-kernel
        `vm_map_protect(` panic string, then find the unique local block matching
        the XNU path that conditionally strips `VM_PROT_WRITE` from a combined
        read+write request before later VM entry updates:

            mov wMask, #6
            bics wzr, wMask, wProt
            b.ne skip
            tbnz wEntryFlags, #22, skip
            ...
            and wProt, wProt, #~VM_PROT_WRITE

        Rewriting the `b.ne` to an unconditional `b` preserves the historical
        patch semantics from `patch_fw.py`: always skip the downgrade block.
        """
        self._log("\n[JB] _vm_map_protect: skip write-downgrade gate")

        foff = self._find_func_by_string(b"vm_map_protect(", self.kern_text)
        if foff < 0:
            self._log("  [-] kernel-text 'vm_map_protect(' anchor not found")
            return False

        func_end = self._find_func_end(foff, 0x2000)
        gate = self._find_write_downgrade_gate(foff, func_end)
        if gate is None:
            self._log("  [-] vm_map_protect write-downgrade gate not found")
            return False

        br_off, target = gate
        b_bytes = self._encode_b(br_off, target)
        if not b_bytes:
            self._log("  [-] branch rewrite out of range")
            return False

        self.emit(br_off, b_bytes, f"b #0x{target - br_off:X} [_vm_map_protect]")
        return True

    def _find_write_downgrade_gate(self, start, end):
        hits = []
        for off in range(start, end - 0x20, 4):
            d = self._disas_at(off, 10)
            if len(d) < 5:
                continue

            mov_mask, bics_insn, bne_insn, tbnz_insn = d[0], d[1], d[2], d[3]
            if mov_mask.mnemonic != "mov" or bics_insn.mnemonic != "bics":
                continue
            if bne_insn.mnemonic != "b.ne" or tbnz_insn.mnemonic != "tbnz":
                continue
            if len(mov_mask.operands) != 2 or len(bics_insn.operands) != 3:
                continue
            if mov_mask.operands[0].type != ARM64_OP_REG or mov_mask.operands[1].type != ARM64_OP_IMM:
                continue
            if mov_mask.operands[1].imm != 6:
                continue

            mask_reg = mov_mask.operands[0].reg
            if bics_insn.operands[0].type != ARM64_OP_REG or bics_insn.operands[0].reg != ARM64_REG_WZR:
                continue
            if bics_insn.operands[1].type != ARM64_OP_REG or bics_insn.operands[1].reg != mask_reg:
                continue
            if bics_insn.operands[2].type != ARM64_OP_REG:
                continue
            prot_reg = bics_insn.operands[2].reg

            if len(bne_insn.operands) != 1 or bne_insn.operands[0].type != ARM64_OP_IMM:
                continue
            if len(tbnz_insn.operands) != 3:
                continue
            if tbnz_insn.operands[0].type != ARM64_OP_REG or tbnz_insn.operands[1].type != ARM64_OP_IMM or tbnz_insn.operands[2].type != ARM64_OP_IMM:
                continue

            target = bne_insn.operands[0].imm
            if target <= bne_insn.address or tbnz_insn.operands[2].imm != target:
                continue
            if tbnz_insn.operands[1].imm != 22:
                continue

            and_off = self._find_write_clear_between(tbnz_insn.address + 4, min(target, end), prot_reg)
            if and_off is None:
                continue

            hits.append((bne_insn.address, target))

        if len(hits) == 1:
            return hits[0]
        return None

    def _find_write_clear_between(self, start, end, prot_reg):
        for off in range(start, end, 4):
            d = self._disas_at(off)
            if not d:
                continue
            insn = d[0]
            if insn.mnemonic != "and" or len(insn.operands) != 3:
                continue
            dst, src, imm = insn.operands
            if dst.type != ARM64_OP_REG or src.type != ARM64_OP_REG or imm.type != ARM64_OP_IMM:
                continue
            if dst.reg != prot_reg or src.reg != prot_reg:
                continue
            imm_val = imm.imm & 0xFFFFFFFF
            if (imm_val & 0x7) == 0x3:
                return off
        return None

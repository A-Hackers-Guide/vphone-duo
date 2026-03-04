"""Mixin: post-validation patches."""

from capstone.arm64_const import ARM64_OP_IMM, ARM64_OP_REG, ARM64_REG_W0

from .kernel_asm import CMP_W0_W0, NOP, _PACIBSP_U32, _rd32


class KernelPatchPostValidationMixin:
    def patch_post_validation_nop(self):
        """Patch 8: NOP the TBNZ after TXM CodeSignature error logging.

        The 'TXM [Error]: CodeSignature: selector: ...' string is followed
        by a BL (printf/log), then a TBNZ that branches to an additional
        validation path.  NOP the TBNZ to skip it.
        """
        self._log("\n[8] post-validation NOP (txm-related)")

        str_off = self.find_string(b"TXM [Error]: CodeSignature")
        if str_off < 0:
            self._log("  [-] 'TXM [Error]: CodeSignature' string not found")
            return False

        refs = self.find_string_refs(str_off, *self.kern_text)
        if not refs:
            refs = self.find_string_refs(str_off)
        if not refs:
            self._log("  [-] no code refs")
            return False

        for adrp_off, add_off, _ in refs:
            # Scan forward past the BL (printf/log) for a TBNZ
            for scan in range(add_off, min(add_off + 0x40, self.size), 4):
                insns = self._disas_at(scan)
                if not insns:
                    continue
                if insns[0].mnemonic == "tbnz":
                    self.emit(
                        scan,
                        NOP,
                        f"NOP {insns[0].mnemonic} {insns[0].op_str} "
                        "[txm post-validation]",
                    )
                    return True

        self._log("  [-] TBNZ not found after TXM error string ref")
        return False

    def patch_post_validation_cmp(self):
        """Patch 9: cmp w0,w0 in postValidation (AMFI code signing).

        The 'AMFI: code signature validation failed' string is in the CALLER
        function, not in postValidation itself.  We find the caller, collect
        its BL targets, then look inside each target for CMP W0, #imm + B.NE.
        """
        self._log("\n[9] postValidation: cmp w0,w0 (AMFI code signing)")

        str_off = self.find_string(b"AMFI: code signature validation failed")
        if str_off < 0:
            self._log("  [-] string not found")
            return False

        refs = self.find_string_refs(str_off, *self.amfi_text)
        if not refs:
            refs = self.find_string_refs(str_off)
        if not refs:
            self._log("  [-] no code refs")
            return False

        caller_start = self.find_function_start(refs[0][0])
        if caller_start < 0:
            self._log("  [-] caller function start not found")
            return False

        # Collect unique BL targets from the caller function
        # Only stop at PACIBSP (new function), not at ret/retab (early returns)
        bl_targets = set()
        for scan in range(caller_start, min(caller_start + 0x2000, self.size), 4):
            if scan > caller_start + 8 and _rd32(self.raw, scan) == _PACIBSP_U32:
                break
            target = self._is_bl(scan)
            if target >= 0:
                bl_targets.add(target)

        # In each BL target in AMFI, look for:  BL ... ; CMP W0, #imm ; B.NE
        # The CMP must check W0 (return value of preceding BL call).
        for target in sorted(bl_targets):
            if not (self.amfi_text[0] <= target < self.amfi_text[1]):
                continue
            for off in range(target, min(target + 0x200, self.size), 4):
                if off > target + 8 and _rd32(self.raw, off) == _PACIBSP_U32:
                    break
                dis = self._disas_at(off, 2)
                if len(dis) < 2:
                    continue
                i0, i1 = dis[0], dis[1]
                if i0.mnemonic != "cmp" or i1.mnemonic != "b.ne":
                    continue
                # Must be CMP W0, #imm (first operand = w0, second = immediate)
                ops = i0.operands
                if len(ops) < 2:
                    continue
                if ops[0].type != ARM64_OP_REG or ops[0].reg != ARM64_REG_W0:
                    continue
                if ops[1].type != ARM64_OP_IMM:
                    continue
                # Must be preceded by a BL within 2 instructions
                has_bl = False
                for gap in (4, 8):
                    if self._is_bl(off - gap) >= 0:
                        has_bl = True
                        break
                if not has_bl:
                    continue
                self.emit(
                    off,
                    CMP_W0_W0,
                    f"cmp w0,w0 (was {i0.mnemonic} {i0.op_str}) [postValidation]",
                )
                return True

        self._log("  [-] CMP+B.NE pattern not found in caller's BL targets")
        return False

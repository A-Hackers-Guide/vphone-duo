"""Mixin: KernelJBPatchVmFaultMixin."""

from .kernel_jb_base import ARM64_OP_REG, ARM64_REG_W0, NOP


class KernelJBPatchVmFaultMixin:
    def patch_vm_fault_enter_prepare(self):
        """NOP a PMAP check in _vm_fault_enter_prepare.
        Find BL to a rarely-called function followed within 4 instructions
        by TBZ/TBNZ on w0.
        """
        self._log("\n[JB] _vm_fault_enter_prepare: NOP")

        # Try symbol first
        foff = self._resolve_symbol("_vm_fault_enter_prepare")
        if foff >= 0:
            func_end = self._find_func_end(foff, 0x2000)
            result = self._find_bl_tbz_pmap(foff + 0x100, func_end)
            if result:
                self.emit(result, NOP, "NOP [_vm_fault_enter_prepare]")
                return True

        # String anchor: all refs to "vm_fault_enter_prepare"
        str_off = self.find_string(b"vm_fault_enter_prepare")
        if str_off >= 0:
            refs = self.find_string_refs(str_off)
            for adrp_off, _, _ in refs:
                func_start = self.find_function_start(adrp_off)
                if func_start < 0:
                    continue
                func_end = self._find_func_end(func_start, 0x4000)
                result = self._find_bl_tbz_pmap(func_start + 0x100, func_end)
                if result:
                    self.emit(result, NOP, "NOP [_vm_fault_enter_prepare]")
                    return True

        # Broader: scan all kern_text for BL to rarely-called func + TBZ w0
        # in a large function (>0x2000 bytes)
        ks, ke = self.kern_text
        for off in range(ks, ke - 16, 4):
            result = self._find_bl_tbz_pmap(off, min(off + 16, ke))
            if result:
                # Verify it's in a large function
                func_start = self.find_function_start(result)
                if func_start >= 0:
                    func_end = self._find_func_end(func_start, 0x4000)
                    if func_end - func_start > 0x2000:
                        self.emit(result, NOP, "NOP [_vm_fault_enter_prepare]")
                        return True

        self._log("  [-] patch site not found")
        return False

    def _find_bl_tbz_pmap(self, start, end):
        """Find BL to a rarely-called function followed within 4 insns by TBZ/TBNZ w0.
        Returns the BL offset, or None."""
        for off in range(start, end - 4, 4):
            d0 = self._disas_at(off)
            if not d0 or d0[0].mnemonic != "bl":
                continue
            bl_target = d0[0].operands[0].imm
            n_callers = len(self.bl_callers.get(bl_target, []))
            if n_callers >= 20:
                continue
            # Check next 4 instructions for TBZ/TBNZ on w0
            for delta in range(1, 5):
                d1 = self._disas_at(off + delta * 4)
                if not d1:
                    break
                i1 = d1[0]
                if i1.mnemonic in ("tbnz", "tbz") and len(i1.operands) >= 2:
                    if (
                        i1.operands[0].type == ARM64_OP_REG
                        and i1.operands[0].reg == ARM64_REG_W0
                    ):
                        return off
        return None

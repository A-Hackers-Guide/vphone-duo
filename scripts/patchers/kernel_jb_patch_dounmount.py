"""Mixin: KernelJBPatchDounmountMixin."""

from .kernel_jb_base import NOP


class KernelJBPatchDounmountMixin:
    def patch_dounmount(self):
        """NOP a MAC check in _dounmount.
        Pattern: mov w1,#0; mov x2,#0; bl TARGET (MAC policy check pattern).
        """
        self._log("\n[JB] _dounmount: NOP")

        # Try symbol first
        foff = self._resolve_symbol("_dounmount")
        if foff >= 0:
            func_end = self._find_func_end(foff, 0x1000)
            result = self._find_mac_check_bl(foff, func_end)
            if result:
                self.emit(result, NOP, "NOP [_dounmount MAC check]")
                return True

        # String anchor: "dounmount:" → find function → search BL targets
        # for the actual _dounmount with MAC check
        str_off = self.find_string(b"dounmount:")
        if str_off >= 0:
            refs = self.find_string_refs(str_off)
            for adrp_off, _, _ in refs:
                caller = self.find_function_start(adrp_off)
                if caller < 0:
                    continue
                caller_end = self._find_func_end(caller, 0x2000)
                # Check BL targets from this function
                for off in range(caller, caller_end, 4):
                    target = self._is_bl(off)
                    if target < 0 or not (
                        self.kern_text[0] <= target < self.kern_text[1]
                    ):
                        continue
                    te = self._find_func_end(target, 0x400)
                    result = self._find_mac_check_bl(target, te)
                    if result:
                        self.emit(result, NOP, "NOP [_dounmount MAC check]")
                        return True

        # Broader: scan kern_text for short functions with MAC check pattern
        ks, ke = self.kern_text
        for off in range(ks, ke - 12, 4):
            d = self._disas_at(off)
            if not d or d[0].mnemonic != "pacibsp":
                continue
            func_end = self._find_func_end(off, 0x400)
            if func_end - off > 0x400:
                continue
            result = self._find_mac_check_bl(off, func_end)
            if result:
                # Verify: function should have "unmount" context
                # (contain a BL to a function also called from known mount code)
                self.emit(result, NOP, "NOP [_dounmount MAC check]")
                return True

        self._log("  [-] patch site not found")
        return False

    def _find_mac_check_bl(self, start, end):
        """Find mov w1,#0; mov x2,#0; bl TARGET pattern. Returns BL offset or None."""
        for off in range(start, end - 8, 4):
            d = self._disas_at(off, 3)
            if len(d) < 3:
                continue
            i0, i1, i2 = d[0], d[1], d[2]
            if i0.mnemonic != "mov" or i1.mnemonic != "mov" or i2.mnemonic != "bl":
                continue
            # Check: mov w1, #0; mov x2, #0
            if "w1" in i0.op_str and "#0" in i0.op_str:
                if "x2" in i1.op_str and "#0" in i1.op_str:
                    return off + 8
            # Also match: mov x2, #0; mov w1, #0
            if "x2" in i0.op_str and "#0" in i0.op_str:
                if "w1" in i1.op_str and "#0" in i1.op_str:
                    return off + 8
        return None

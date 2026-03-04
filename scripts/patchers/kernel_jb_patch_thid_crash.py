"""Mixin: KernelJBPatchThidCrashMixin."""

from .kernel_jb_base import _rd32, _rd64


class KernelJBPatchThidCrashMixin:
    def patch_thid_should_crash(self):
        """Zero out _thid_should_crash global variable.
        Anchor: 'thid_should_crash' string in __DATA → nearby sysctl_oid struct
        contains a raw pointer (low32 = file offset) to the variable.
        """
        self._log("\n[JB] _thid_should_crash: zero out")

        # Try symbol first
        foff = self._resolve_symbol("_thid_should_crash")
        if foff >= 0:
            self.emit(foff, b"\x00\x00\x00\x00", "zero [_thid_should_crash]")
            return True

        # Find the string in __DATA (sysctl name string)
        str_off = self.find_string(b"thid_should_crash")
        if str_off < 0:
            self._log("  [-] string not found")
            return False

        self._log(f"  [*] string at foff 0x{str_off:X}")

        # The sysctl_oid struct is near the string in __DATA.
        # It contains 8-byte entries, one of which has its low32 bits
        # equal to the file offset of the variable (chained fixup encoding).
        # The variable is a 4-byte int (typically value 1) in __DATA_CONST.
        #
        # Search forward from the string for 8-byte values whose low32
        # points to a valid location holding a small non-zero value.
        data_const_ranges = [
            (fo, fo + fs)
            for name, _, fo, fs, _ in self.all_segments
            if name in ("__DATA_CONST",) and fs > 0
        ]

        for delta in range(0, 128, 8):
            check = str_off + delta
            if check + 8 > self.size:
                break
            val = _rd64(self.raw, check)
            if val == 0:
                continue
            low32 = val & 0xFFFFFFFF
            # The variable should be in __DATA_CONST or __DATA
            if low32 == 0 or low32 >= self.size:
                continue
            # Check if low32 points to a location holding a small int (1-255)
            target_val = _rd32(self.raw, low32)
            if 1 <= target_val <= 255:
                # Verify it's in a data segment (not code)
                in_data = any(s <= low32 < e for s, e in data_const_ranges)
                if not in_data:
                    # Also accept __DATA segments
                    in_data = any(
                        fo <= low32 < fo + fs
                        for name, _, fo, fs, _ in self.all_segments
                        if "DATA" in name and fs > 0
                    )
                if in_data:
                    self._log(
                        f"  [+] variable at foff 0x{low32:X} "
                        f"(value={target_val}, found via sysctl_oid "
                        f"at str+0x{delta:X})"
                    )
                    self.emit(low32, b"\x00\x00\x00\x00", "zero [_thid_should_crash]")
                    return True

        # Fallback: if string has code refs, search via ADRP+ADD
        refs = self.find_string_refs(str_off)
        if refs:
            func_start = self.find_function_start(refs[0][0])
            if func_start >= 0:
                func_end = self._find_func_end(func_start, 0x200)
                for off in range(func_start, func_end - 4, 4):
                    d = self._disas_at(off, 2)
                    if len(d) < 2:
                        continue
                    i0, i1 = d[0], d[1]
                    if i0.mnemonic == "adrp" and i1.mnemonic == "add":
                        page = (i0.operands[1].imm - self.base_va) & ~0xFFF
                        imm12 = i1.operands[2].imm if len(i1.operands) > 2 else 0
                        target = page + imm12
                        if 0 < target < self.size:
                            tv = _rd32(self.raw, target)
                            if 1 <= tv <= 255:
                                self.emit(
                                    target,
                                    b"\x00\x00\x00\x00",
                                    "zero [_thid_should_crash]",
                                )
                                return True

        self._log("  [-] variable not found")
        return False

    # ══════════════════════════════════════════════════════════════
    # Group C: Complex shellcode patches
    # ══════════════════════════════════════════════════════════════

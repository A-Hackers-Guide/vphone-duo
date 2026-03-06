"""Mixin: KernelJBPatchThidCrashMixin."""

from .kernel_jb_base import _rd32, _rd64


class KernelJBPatchThidCrashMixin:
    def patch_thid_should_crash(self):
        """Zero out `_thid_should_crash` via the nearby sysctl metadata.

        The raw PCC 26.1 kernels do not provide a usable runtime symbol table,
        so this patch always resolves through the sysctl name string
        `thid_should_crash` and the adjacent `sysctl_oid` data.
        """
        self._log("\n[JB] _thid_should_crash: zero out")

        str_off = self.find_string(b"thid_should_crash")
        if str_off < 0:
            self._log("  [-] string not found")
            return False

        self._log(f"  [*] string at foff 0x{str_off:X}")

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
            if low32 == 0 or low32 >= self.size:
                continue
            target_val = _rd32(self.raw, low32)
            if 1 <= target_val <= 255:
                in_data = any(s <= low32 < e for s, e in data_const_ranges)
                if not in_data:
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

        self._log("  [-] variable not found")
        return False

    # ══════════════════════════════════════════════════════════════
    # Group C: Complex shellcode patches
    # ══════════════════════════════════════════════════════════════

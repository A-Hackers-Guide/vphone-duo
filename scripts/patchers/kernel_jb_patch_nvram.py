"""Mixin: KernelJBPatchNvramMixin."""

from .kernel_jb_base import NOP


class KernelJBPatchNvramMixin:
    def patch_nvram_verify_permission(self):
        """NOP verification in IONVRAMController's verifyPermission.
        Anchor: 'krn.' string (NVRAM key prefix) → xref → function → TBZ/TBNZ.
        """
        self._log("\n[JB] verifyPermission (NVRAM): NOP")

        # Try symbol first
        sym_off = self._resolve_symbol(
            "__ZL16verifyPermission16IONVRAMOperationPKhPKcb"
        )
        if sym_off < 0:
            for sym, off in self.symbols.items():
                if "verifyPermission" in sym and "NVRAM" in sym:
                    sym_off = off
                    break

        # String anchor: "krn." is referenced in verifyPermission.
        # The TBZ/TBNZ guard is immediately before the ADRP+ADD that
        # loads the "krn." string, so search backward from that ref.
        str_off = self.find_string(b"krn.")
        ref_off = -1
        if str_off >= 0:
            refs = self.find_string_refs(str_off)
            if refs:
                ref_off = refs[0][0]  # ADRP instruction offset

        foff = (
            sym_off
            if sym_off >= 0
            else (self.find_function_start(ref_off) if ref_off >= 0 else -1)
        )

        if foff < 0:
            # Fallback: try NVRAM entitlement string
            ent_off = self.find_string(b"com.apple.private.iokit.nvram-write-access")
            if ent_off >= 0:
                ent_refs = self.find_string_refs(ent_off)
                if ent_refs:
                    foff = self.find_function_start(ent_refs[0][0])

        if foff < 0:
            self._log("  [-] function not found")
            return False

        func_end = self._find_func_end(foff, 0x600)

        # Strategy 1: search backward from "krn." string ref for
        # nearest TBZ/TBNZ — the guard branch is typically within
        # a few instructions before the ADRP that loads "krn.".
        if ref_off > foff:
            for off in range(ref_off - 4, max(foff - 4, ref_off - 0x20), -4):
                d = self._disas_at(off)
                if d and d[0].mnemonic in ("tbnz", "tbz"):
                    self.emit(off, NOP, "NOP [verifyPermission NVRAM]")
                    return True

        # Strategy 2: scan full function for first TBZ/TBNZ
        for off in range(foff, func_end, 4):
            d = self._disas_at(off)
            if not d:
                continue
            if d[0].mnemonic in ("tbnz", "tbz"):
                self.emit(off, NOP, "NOP [verifyPermission NVRAM]")
                return True

        self._log("  [-] TBZ/TBNZ not found in function")
        return False

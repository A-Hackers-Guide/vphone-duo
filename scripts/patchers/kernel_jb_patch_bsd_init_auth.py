"""Mixin: KernelJBPatchBsdInitAuthMixin."""

from .kernel_jb_base import MOV_X0_0


class KernelJBPatchBsdInitAuthMixin:
    def patch_bsd_init_auth(self):
        """Bypass rootvp authentication check in _bsd_init.
        Pattern: ldr x0, [xN, #0x2b8]; cbz x0, ...; bl AUTH_FUNC
        Replace the BL with mov x0, #0.
        """
        self._log("\n[JB] _bsd_init: mov x0,#0 (auth bypass)")

        # Try symbol first
        foff = self._resolve_symbol("_bsd_init")
        if foff >= 0:
            func_end = self._find_func_end(foff, 0x2000)
            result = self._find_auth_bl(foff, func_end)
            if result:
                self.emit(result, MOV_X0_0, "mov x0,#0 [_bsd_init auth]")
                return True

        # Pattern search: ldr x0, [xN, #0x2b8]; cbz x0; bl
        ks, ke = self.kern_text
        candidates = []
        for off in range(ks, ke - 8, 4):
            d = self._disas_at(off, 3)
            if len(d) < 3:
                continue
            i0, i1, i2 = d[0], d[1], d[2]
            if i0.mnemonic != "ldr" or i1.mnemonic != "cbz" or i2.mnemonic != "bl":
                continue
            if not i0.op_str.startswith("x0,"):
                continue
            if "#0x2b8" not in i0.op_str:
                continue
            if not i1.op_str.startswith("x0,"):
                continue
            candidates.append(off + 8)  # the BL offset

        if not candidates:
            self._log("  [-] ldr+cbz+bl pattern not found")
            return False

        # Filter to kern_text range (exclude kexts)
        kern_candidates = [c for c in candidates if ks <= c < ke]
        if not kern_candidates:
            kern_candidates = candidates

        # Pick the last one in the kernel (bsd_init is typically late in boot)
        bl_off = kern_candidates[-1]
        self._log(
            f"  [+] auth BL at 0x{bl_off:X} ({len(kern_candidates)} kern candidates)"
        )
        self.emit(bl_off, MOV_X0_0, "mov x0,#0 [_bsd_init auth]")
        return True

    def _find_auth_bl(self, start, end):
        """Find ldr x0,[xN,#0x2b8]; cbz x0; bl pattern. Returns BL offset."""
        for off in range(start, end - 8, 4):
            d = self._disas_at(off, 3)
            if len(d) < 3:
                continue
            i0, i1, i2 = d[0], d[1], d[2]
            if i0.mnemonic == "ldr" and i1.mnemonic == "cbz" and i2.mnemonic == "bl":
                if i0.op_str.startswith("x0,") and "#0x2b8" in i0.op_str:
                    if i1.op_str.startswith("x0,"):
                        return off + 8
        return None

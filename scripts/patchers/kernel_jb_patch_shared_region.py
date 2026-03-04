"""Mixin: KernelJBPatchSharedRegionMixin."""

from .kernel_jb_base import ARM64_OP_REG, CMP_X0_X0


class KernelJBPatchSharedRegionMixin:
    def patch_shared_region_map(self):
        """Force shared region check: cmp x0,x0.
        Anchor: '/private/preboot/Cryptexes' string → function → CMP+B.NE.
        """
        self._log("\n[JB] _shared_region_map_and_slide_setup: cmp x0,x0")

        # Try symbol first
        foff = self._resolve_symbol("_shared_region_map_and_slide_setup")
        if foff < 0:
            foff = self._find_func_by_string(
                b"/private/preboot/Cryptexes", self.kern_text
            )
        if foff < 0:
            foff = self._find_func_by_string(b"/private/preboot/Cryptexes")
        if foff < 0:
            self._log("  [-] function not found")
            return False

        func_end = self._find_func_end(foff, 0x2000)

        for off in range(foff, func_end - 4, 4):
            d = self._disas_at(off, 2)
            if len(d) < 2:
                continue
            i0, i1 = d[0], d[1]
            if i0.mnemonic != "cmp" or i1.mnemonic != "b.ne":
                continue
            ops = i0.operands
            if len(ops) < 2:
                continue
            if ops[0].type == ARM64_OP_REG and ops[1].type == ARM64_OP_REG:
                self.emit(
                    off, CMP_X0_X0, "cmp x0,x0 [_shared_region_map_and_slide_setup]"
                )
                return True

        self._log("  [-] CMP+B.NE pattern not found")
        return False

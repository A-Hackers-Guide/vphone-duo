"""Mixin: bsd_init rootvp patch."""

from .kernel_asm import MOV_X0_0, NOP


class KernelPatchBsdInitMixin:
    def patch_bsd_init_rootvp(self):
        """Patch 3: NOP the conditional branch guarding the 'rootvp not authenticated' panic."""
        self._log("\n[3] _bsd_init: rootvp not authenticated panic")

        str_off = self.find_string(b"rootvp not authenticated after mounting")
        if str_off < 0:
            self._log("  [-] string not found")
            return False

        refs = self.find_string_refs(str_off, *self.kern_text)
        if not refs:
            self._log("  [-] no code refs in kernel __text")
            return False

        for adrp_off, add_off, _ in refs:
            # Find the BL _panic after the string ref
            bl_panic_off = -1
            for scan in range(add_off, min(add_off + 0x40, self.size), 4):
                bl_target = self._is_bl(scan)
                if bl_target == self.panic_off:
                    bl_panic_off = scan
                    break

            if bl_panic_off < 0:
                continue

            # Search backwards for a conditional branch whose target is in
            # the error path (the block ending with BL _panic).
            # The error path is typically a few instructions before BL _panic.
            err_lo = bl_panic_off - 0x40  # error block start (generous)
            err_hi = bl_panic_off + 4  # error block end

            for back in range(adrp_off - 4, max(adrp_off - 0x400, 0), -4):
                target, kind = self._decode_branch_target(back)
                if target is not None and err_lo <= target <= err_hi:
                    self.emit(back, NOP, f"NOP {kind} (rootvp auth) [_bsd_init]")
                    return True

        self._log("  [-] conditional branch into panic path not found")
        return False

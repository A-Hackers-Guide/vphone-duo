"""Mixin: APFS seal broken patch."""

from .kernel_asm import NOP


class KernelPatchApfsSealMixin:
    def patch_apfs_seal_broken(self):
        """Patch 2: NOP the conditional branch leading to 'root volume seal is broken' panic."""
        self._log("\n[2] _authapfs_seal_is_broken: seal broken panic")

        str_off = self.find_string(b"root volume seal is broken")
        if str_off < 0:
            self._log("  [-] string not found")
            return False

        refs = self.find_string_refs(str_off, *self.apfs_text)
        if not refs:
            self._log("  [-] no code refs")
            return False

        for adrp_off, add_off, _ in refs:
            # Find BL _panic after string ref
            bl_off = -1
            for scan in range(add_off, min(add_off + 0x40, self.size), 4):
                bl_target = self._is_bl(scan)
                if bl_target == self.panic_off:
                    bl_off = scan
                    break

            if bl_off < 0:
                continue

            # Search backwards for a conditional branch that jumps INTO the
            # panic path.  The error block may set up __FILE__/line args
            # before the string ADRP, so allow target up to 0x40 before it.
            err_lo = adrp_off - 0x40
            for back in range(adrp_off - 4, max(adrp_off - 0x200, 0), -4):
                target, kind = self._decode_branch_target(back)
                if target is not None and err_lo <= target <= bl_off + 4:
                    self.emit(
                        back,
                        NOP,
                        f"NOP {kind} (seal broken) [_authapfs_seal_is_broken]",
                    )
                    return True

        self._log("  [-] could not find conditional branch to NOP")
        return False

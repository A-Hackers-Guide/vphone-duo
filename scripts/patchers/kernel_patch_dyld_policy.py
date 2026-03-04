"""Mixin: dyld policy patch."""

from .kernel_asm import MOV_W0_1


class KernelPatchDyldPolicyMixin:
    def patch_check_dyld_policy(self):
        """Patches 10-11: Replace two BL calls in _check_dyld_policy_internal with mov w0,#1.

        The function is found via its reference to the Swift Playgrounds
        entitlement string.  The two BLs immediately preceding that string
        reference (each followed by a conditional branch on w0) are patched.
        """
        self._log("\n[10-11] _check_dyld_policy_internal: mov w0,#1 (two BLs)")

        # Anchor: entitlement string referenced from within the function
        str_off = self.find_string(
            b"com.apple.developer.swift-playgrounds-app.development-build"
        )
        if str_off < 0:
            self._log("  [-] swift-playgrounds entitlement string not found")
            return False

        refs = self.find_string_refs(str_off, *self.amfi_text)
        if not refs:
            refs = self.find_string_refs(str_off)
        if not refs:
            self._log("  [-] no code refs in AMFI")
            return False

        for adrp_off, add_off, _ in refs:
            # Walk backward from the ADRP, looking for BL + conditional-on-w0 pairs
            bls_with_cond = []  # [(bl_off, bl_target), ...]
            for back in range(adrp_off - 4, max(adrp_off - 80, 0), -4):
                bl_target = self._is_bl(back)
                if bl_target < 0:
                    continue
                if self._is_cond_branch_w0(back + 4):
                    bls_with_cond.append((back, bl_target))

            if len(bls_with_cond) >= 2:
                bl2_off, bl2_tgt = bls_with_cond[0]  # closer  to ADRP
                bl1_off, bl1_tgt = bls_with_cond[1]  # farther from ADRP
                # The two BLs must call DIFFERENT functions — this
                # distinguishes _check_dyld_policy_internal from other
                # functions that repeat calls to the same helper.
                if bl1_tgt == bl2_tgt:
                    continue
                self.emit(
                    bl1_off,
                    MOV_W0_1,
                    "mov w0,#1 (was BL) [_check_dyld_policy_internal @1]",
                )
                self.emit(
                    bl2_off,
                    MOV_W0_1,
                    "mov w0,#1 (was BL) [_check_dyld_policy_internal @2]",
                )
                return True

        self._log("  [-] _check_dyld_policy_internal BL pair not found")
        return False

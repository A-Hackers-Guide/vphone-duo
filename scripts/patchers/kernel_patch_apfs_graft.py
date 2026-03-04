"""Mixin: APFS graft and fsioc helpers."""

from .kernel_asm import MOV_W0_0, _PACIBSP_U32, _rd32


class KernelPatchApfsGraftMixin:
    def _find_validate_root_hash_func(self):
        """Find validate_on_disk_root_hash function via 'authenticate_root_hash' string."""
        str_off = self.find_string(b"authenticate_root_hash")
        if str_off < 0:
            return -1
        refs = self.find_string_refs(str_off, *self.apfs_text)
        if not refs:
            return -1
        return self.find_function_start(refs[0][0])

    def patch_apfs_graft(self):
        """Patch 12: Replace BL to validate_on_disk_root_hash with mov w0,#0.

        Instead of stubbing _apfs_graft at entry, find the specific BL
        that calls the root hash validation and neutralize just that call.
        """
        self._log("\n[12] _apfs_graft: mov w0,#0 (validate_root_hash BL)")

        # Find _apfs_graft function
        exact = self.raw.find(b"\x00apfs_graft\x00")
        if exact < 0:
            self._log("  [-] 'apfs_graft' string not found")
            return False
        str_off = exact + 1

        refs = self.find_string_refs(str_off, *self.apfs_text)
        if not refs:
            self._log("  [-] no code refs")
            return False

        graft_start = self.find_function_start(refs[0][0])
        if graft_start < 0:
            self._log("  [-] _apfs_graft function start not found")
            return False

        # Find validate_on_disk_root_hash function
        vrh_func = self._find_validate_root_hash_func()
        if vrh_func < 0:
            self._log("  [-] validate_on_disk_root_hash not found")
            return False

        # Scan _apfs_graft for BL to validate_on_disk_root_hash
        # Don't stop at ret/retab (early returns) — only stop at PACIBSP (new function)
        for scan in range(graft_start, min(graft_start + 0x2000, self.size), 4):
            if scan > graft_start + 8 and _rd32(self.raw, scan) == _PACIBSP_U32:
                break
            bl_target = self._is_bl(scan)
            if bl_target == vrh_func:
                self.emit(scan, MOV_W0_0, "mov w0,#0 [_apfs_graft]")
                return True

        self._log("  [-] BL to validate_on_disk_root_hash not found in _apfs_graft")
        return False
    def _find_validate_payload_manifest_func(self):
        """Find the AppleImage4 validate_payload_and_manifest function."""
        str_off = self.find_string(b"validate_payload_and_manifest")
        if str_off < 0:
            return -1
        refs = self.find_string_refs(str_off, *self.apfs_text)
        if not refs:
            return -1
        return self.find_function_start(refs[0][0])

    def patch_handle_fsioc_graft(self):
        """Patch 15: Replace BL to validate_payload_and_manifest with mov w0,#0.

        Instead of stubbing _handle_fsioc_graft at entry, find the specific
        BL that calls AppleImage4 validation and neutralize just that call.
        """
        self._log("\n[15] _handle_fsioc_graft: mov w0,#0 (validate BL)")

        exact = self.raw.find(b"\x00handle_fsioc_graft\x00")
        if exact < 0:
            self._log("  [-] 'handle_fsioc_graft' string not found")
            return False
        str_off = exact + 1

        refs = self.find_string_refs(str_off, *self.apfs_text)
        if not refs:
            self._log("  [-] no code refs")
            return False

        fsioc_start = self.find_function_start(refs[0][0])
        if fsioc_start < 0:
            self._log("  [-] function start not found")
            return False

        # Find the validation function
        val_func = self._find_validate_payload_manifest_func()
        if val_func < 0:
            self._log("  [-] validate_payload_and_manifest not found")
            return False

        # Scan _handle_fsioc_graft for BL to validation function
        for scan in range(fsioc_start, min(fsioc_start + 0x400, self.size), 4):
            insns = self._disas_at(scan)
            if not insns:
                continue
            if scan > fsioc_start + 8 and insns[0].mnemonic == "pacibsp":
                break
            bl_target = self._is_bl(scan)
            if bl_target == val_func:
                self.emit(scan, MOV_W0_0, "mov w0,#0 [_handle_fsioc_graft]")
                return True

        self._log("  [-] BL to validate_payload_and_manifest not found")
        return False

    # ── Sandbox MACF hooks ───────────────────────────────────────

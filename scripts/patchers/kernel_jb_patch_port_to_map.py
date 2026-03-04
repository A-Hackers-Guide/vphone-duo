"""Mixin: KernelJBPatchPortToMapMixin."""

from .kernel_jb_base import ARM64_OP_IMM


class KernelJBPatchPortToMapMixin:
    def patch_convert_port_to_map(self):
        """Skip panic in _convert_port_to_map_with_flavor.
        Anchor: 'userspace has control access to a kernel map' panic string.
        """
        self._log("\n[JB] _convert_port_to_map_with_flavor: skip panic")

        str_off = self.find_string(b"userspace has control access to a kernel map")
        if str_off < 0:
            self._log("  [-] panic string not found")
            return False

        refs = self.find_string_refs(str_off, *self.kern_text)
        if not refs:
            self._log("  [-] no code refs")
            return False

        for adrp_off, add_off, _ in refs:
            bl_panic = self._find_bl_to_panic_in_range(
                add_off, min(add_off + 0x40, self.size)
            )
            if bl_panic < 0:
                continue
            resume_off = bl_panic + 4
            err_lo = adrp_off - 0x40
            for back in range(adrp_off - 4, max(adrp_off - 0x200, 0), -4):
                target, kind = self._decode_branch_target(back)
                if target is not None and err_lo <= target <= bl_panic + 4:
                    b_bytes = self._encode_b(back, resume_off)
                    if b_bytes:
                        self.emit(
                            back,
                            b_bytes,
                            f"b #0x{resume_off - back:X} "
                            f"[_convert_port_to_map skip panic]",
                        )
                        return True

        self._log("  [-] branch site not found")
        return False

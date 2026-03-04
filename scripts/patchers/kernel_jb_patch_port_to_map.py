"""Mixin: KernelJBPatchPortToMapMixin."""

from .kernel_jb_base import ARM64_OP_IMM, NOP, struct, _rd32


class KernelJBPatchPortToMapMixin:
    def patch_convert_port_to_map(self):
        """Skip panic in _convert_port_to_map_with_flavor.

        Anchor: 'userspace has control access to a kernel map' panic string.

        The function flow around the kernel_map check is:
            CMP  X16, X8      ; compare map ptr with kernel_map
            B.NE normal_path  ; if NOT kernel_map, continue normally
            ; fall through: set up panic args and call _panic (noreturn)

        Fix: walk backward from the string ref to find the B.cond that
        guards the panic fall-through, then make it unconditional.
        This causes the kernel_map case to take the normal path instead
        of panicking, allowing userspace to access the kernel map.
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
            # Walk backward from the string ADRP to find CMP + B.cond
            # The pattern is: CMP Xn, Xm; B.NE target
            # We want to change B.NE to unconditional B (always skip panic).
            for back in range(adrp_off - 4, max(adrp_off - 0x60, 0), -4):
                d = self._disas_at(back, 2)
                if not d or len(d) < 2:
                    continue
                i0, i1 = d[0], d[1]
                # Look for CMP + B.NE/B.CS/B.HI (conditional branch away from
                # the panic path). The branch target should be AFTER the panic
                # call (i.e., forward past the string ref region).
                if i0.mnemonic != "cmp":
                    continue
                if not i1.mnemonic.startswith("b."):
                    continue
                # Decode the branch target
                target, kind = self._decode_branch_target(back + 4)
                if target is None:
                    continue
                # The branch should go FORWARD past the panic (beyond adrp_off)
                if target <= adrp_off:
                    continue

                # Found the conditional branch that skips the panic path.
                # Replace it with unconditional B to same target.
                b_bytes = self._encode_b(back + 4, target)
                if b_bytes:
                    self.emit(
                        back + 4,
                        b_bytes,
                        f"b 0x{target:X} "
                        f"[_convert_port_to_map skip panic]",
                    )
                    return True

        self._log("  [-] branch site not found")
        return False

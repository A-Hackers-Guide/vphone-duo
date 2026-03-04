"""Mixin: KernelJBPatchVmProtectMixin."""

from .kernel_jb_base import ARM64_OP_IMM


class KernelJBPatchVmProtectMixin:
    def patch_vm_map_protect(self):
        """Skip a check in _vm_map_protect: branch over guard.
        Anchor: 'vm_map_protect(' panic string → function → TBNZ with high bit.
        """
        self._log("\n[JB] _vm_map_protect: skip check")

        # Try symbol first
        foff = self._resolve_symbol("_vm_map_protect")
        if foff < 0:
            # String anchor
            foff = self._find_func_by_string(b"vm_map_protect(", self.kern_text)
        if foff < 0:
            foff = self._find_func_by_string(b"vm_map_protect(")
        if foff < 0:
            self._log("  [-] function not found")
            return False

        func_end = self._find_func_end(foff, 0x2000)

        # Find TBNZ with bit >= 24 that branches forward (permission check guard)
        for off in range(foff, func_end - 4, 4):
            d = self._disas_at(off)
            if not d:
                continue
            i = d[0]
            if i.mnemonic != "tbnz":
                continue
            if len(i.operands) < 3:
                continue
            bit_op = i.operands[1]
            if bit_op.type == ARM64_OP_IMM and bit_op.imm >= 24:
                target = i.operands[2].imm if i.operands[2].type == ARM64_OP_IMM else -1
                if target > off:
                    b_bytes = self._encode_b(off, target)
                    if b_bytes:
                        self.emit(
                            off, b_bytes, f"b #0x{target - off:X} [_vm_map_protect]"
                        )
                        return True

        self._log("  [-] patch site not found")
        return False

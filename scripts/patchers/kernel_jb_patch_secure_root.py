"""Mixin: KernelJBPatchSecureRootMixin."""

from .kernel_jb_base import ARM64_OP_IMM


class KernelJBPatchSecureRootMixin:
    def patch_io_secure_bsd_root(self):
        """Skip security check in _IOSecureBSDRoot.
        Anchor: 'SecureRootName' string → function → CBZ/CBNZ → unconditional B.
        """
        self._log("\n[JB] _IOSecureBSDRoot: skip check")

        # Try symbol first
        foff = self._resolve_symbol("_IOSecureBSDRoot")
        if foff < 0:
            foff = self._find_func_by_string(b"SecureRootName")
        if foff < 0:
            self._log("  [-] function not found")
            return False

        func_end = self._find_func_end(foff, 0x400)

        for off in range(foff, func_end - 4, 4):
            d = self._disas_at(off)
            if not d:
                continue
            i = d[0]
            if i.mnemonic in ("cbnz", "cbz", "tbnz", "tbz"):
                target = None
                for op in reversed(i.operands):
                    if op.type == ARM64_OP_IMM:
                        target = op.imm
                        break
                if target and target > off:
                    b_bytes = self._encode_b(off, target)
                    if b_bytes:
                        self.emit(
                            off, b_bytes, f"b #0x{target - off:X} [_IOSecureBSDRoot]"
                        )
                        return True

        self._log("  [-] conditional branch not found")
        return False

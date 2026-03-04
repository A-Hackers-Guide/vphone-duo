"""Mixin: APFS root snapshot patch."""

from capstone.arm64_const import ARM64_OP_IMM, ARM64_OP_REG

from .kernel_asm import NOP


class KernelPatchApfsSnapshotMixin:
    def patch_apfs_root_snapshot(self):
        """Patch 1: NOP the tbnz w8,#5 that gates sealed-volume root snapshot panic."""
        self._log("\n[1] _apfs_vfsop_mount: root snapshot sealed volume check")

        refs = self._find_by_string_in_range(
            b"Rooting from snapshot with xid", self.apfs_text, "apfs_vfsop_mount log"
        )
        if not refs:
            refs = self._find_by_string_in_range(
                b"Failed to find the root snapshot",
                self.apfs_text,
                "root snapshot panic",
            )
            if not refs:
                return False

        for adrp_off, add_off, _ in refs:
            for scan in range(add_off, min(add_off + 0x200, self.size), 4):
                insns = self._disas_at(scan)
                if not insns:
                    continue
                i = insns[0]
                if i.mnemonic not in ("tbnz", "tbz"):
                    continue
                # Check: tbz/tbnz w8, #5, ...
                ops = i.operands
                if (
                    len(ops) >= 2
                    and ops[0].type == ARM64_OP_REG
                    and ops[1].type == ARM64_OP_IMM
                    and ops[1].imm == 5
                ):
                    self.emit(
                        scan,
                        NOP,
                        f"NOP {i.mnemonic} {i.op_str} "
                        "(sealed vol check) [_apfs_vfsop_mount]",
                    )
                    return True

        self._log("  [-] tbz/tbnz w8,#5 not found near xref")
        return False

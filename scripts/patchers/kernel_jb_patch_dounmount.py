"""Mixin: KernelJBPatchDounmountMixin."""

from capstone.arm64_const import ARM64_OP_IMM, ARM64_OP_REG

from .kernel_jb_base import NOP


class KernelJBPatchDounmountMixin:
    def patch_dounmount(self):
        """Match the known-good upstream cleanup call in dounmount.

        Anchor class: string anchor. Recover the dounmount body through the
        stable panic string `dounmount:` and patch the unique near-tail 4-arg
        zeroed cleanup call used by `/Users/qaq/Desktop/patch_fw.py`:

            mov x0, xMountLike
            mov w1, #0
            mov w2, #0
            mov w3, #0
            bl  target
            mov x0, xMountLike
            bl  target2
            cbz x19, ...

        This intentionally rejects the later `mov w1,#0x10 ; mov x2,#0 ; bl`
        site because that drifted away from upstream and represents a different
        call signature/control-flow path.
        """
        self._log("\n[JB] _dounmount: upstream cleanup-call NOP")

        foff = self._find_func_by_string(b"dounmount:", self.kern_text)
        if foff < 0:
            self._log("  [-] 'dounmount:' anchor not found")
            return False

        func_end = self._find_func_end(foff, 0x4000)
        patch_off = self._find_upstream_cleanup_call(foff, func_end)
        if patch_off is None:
            self._log("  [-] upstream dounmount cleanup call not found")
            return False

        self.emit(patch_off, NOP, "NOP [_dounmount upstream cleanup call]")
        return True

    def _find_upstream_cleanup_call(self, start, end):
        hits = []
        for off in range(start, end - 0x1C, 4):
            d = self._disas_at(off, 8)
            if len(d) < 8:
                continue
            i0, i1, i2, i3, i4, i5, i6, i7 = d
            if i0.mnemonic != "mov" or i1.mnemonic != "mov" or i2.mnemonic != "mov" or i3.mnemonic != "mov":
                continue
            if i4.mnemonic != "bl" or i5.mnemonic != "mov" or i6.mnemonic != "bl":
                continue
            if i7.mnemonic != "cbz":
                continue

            src_reg = self._mov_reg_reg(i0, "x0")
            if src_reg is None:
                continue
            if not self._mov_imm_zero(i1, "w1"):
                continue
            if not self._mov_imm_zero(i2, "w2"):
                continue
            if not self._mov_imm_zero(i3, "w3"):
                continue
            if not self._mov_reg_reg(i5, "x0", src_reg):
                continue
            if not self._cbz_uses_xreg(i7):
                continue
            hits.append(i4.address)

        if len(hits) == 1:
            return hits[0]
        return None

    def _mov_reg_reg(self, insn, dst_name, src_name=None):
        if insn.mnemonic != "mov" or len(insn.operands) != 2:
            return None
        dst, src = insn.operands
        if dst.type != ARM64_OP_REG or src.type != ARM64_OP_REG:
            return None
        if insn.reg_name(dst.reg) != dst_name:
            return None
        src_reg = insn.reg_name(src.reg)
        if src_name is not None and src_reg != src_name:
            return None
        return src_reg

    def _mov_imm_zero(self, insn, dst_name):
        if insn.mnemonic != "mov" or len(insn.operands) != 2:
            return False
        dst, src = insn.operands
        return (
            dst.type == ARM64_OP_REG
            and insn.reg_name(dst.reg) == dst_name
            and src.type == ARM64_OP_IMM
            and src.imm == 0
        )

    def _cbz_uses_xreg(self, insn):
        if len(insn.operands) != 2:
            return False
        reg_op, imm_op = insn.operands
        return reg_op.type == ARM64_OP_REG and imm_op.type == ARM64_OP_IMM and insn.reg_name(reg_op.reg).startswith("x")

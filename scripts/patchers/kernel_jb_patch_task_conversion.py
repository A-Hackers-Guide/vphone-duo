"""Mixin: KernelJBPatchTaskConversionMixin."""

from .kernel_jb_base import ARM64_OP_REG, ARM64_OP_MEM, ARM64_REG_X0, ARM64_REG_X1, CMP_XZR_XZR


class KernelJBPatchTaskConversionMixin:
    def patch_task_conversion_eval_internal(self):
        """Allow task conversion: cmp Xn,x0 -> cmp xzr,xzr at unique guard site."""
        self._log("\n[JB] task_conversion_eval_internal: cmp xzr,xzr")

        candidates = []
        ks, ke = self.kern_text
        for off in range(ks + 4, ke - 12, 4):
            d0 = self._disas_at(off)
            if not d0:
                continue
            i0 = d0[0]
            if i0.mnemonic != "cmp" or len(i0.operands) < 2:
                continue
            a0, a1 = i0.operands[0], i0.operands[1]
            if not (a0.type == ARM64_OP_REG and a1.type == ARM64_OP_REG):
                continue
            if a1.reg != ARM64_REG_X0:
                continue
            cmp_reg = a0.reg

            dp = self._disas_at(off - 4)
            d1 = self._disas_at(off + 4)
            d2 = self._disas_at(off + 8)
            d3 = self._disas_at(off + 12)
            if not dp or not d1 or not d2 or not d3:
                continue
            p = dp[0]
            i1, i2, i3 = d1[0], d2[0], d3[0]

            if p.mnemonic != "ldr" or len(p.operands) < 2:
                continue
            p0, p1 = p.operands[0], p.operands[1]
            if p0.type != ARM64_OP_REG or p0.reg != cmp_reg:
                continue
            if p1.type != ARM64_OP_MEM:
                continue
            if p1.mem.base != cmp_reg:
                continue

            if i1.mnemonic != "b.eq":
                continue
            if i2.mnemonic != "cmp" or len(i2.operands) < 2:
                continue
            j0, j1 = i2.operands[0], i2.operands[1]
            if not (j0.type == ARM64_OP_REG and j1.type == ARM64_OP_REG):
                continue
            if not (j0.reg == cmp_reg and j1.reg == ARM64_REG_X1):
                continue
            if i3.mnemonic != "b.eq":
                continue

            candidates.append(off)

        if len(candidates) != 1:
            self._log(
                f"  [-] expected 1 task-conversion guard site, found {len(candidates)}"
            )
            return False

        self.emit(
            candidates[0], CMP_XZR_XZR, "cmp xzr,xzr [_task_conversion_eval_internal]"
        )
        return True

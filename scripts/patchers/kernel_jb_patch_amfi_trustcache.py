"""Mixin: KernelJBPatchAmfiTrustcacheMixin."""

from .kernel_jb_base import MOV_X0_1, CBZ_X2_8, STR_X0_X2, RET


class KernelJBPatchAmfiTrustcacheMixin:
    def patch_amfi_cdhash_in_trustcache(self):
        """AMFIIsCDHashInTrustCache rewrite (semantic function matching)."""
        self._log("\n[JB] AMFIIsCDHashInTrustCache: always allow + store flag")

        def _find_after(insns, start, pred):
            for idx in range(start, len(insns)):
                if pred(insns[idx]):
                    return idx
            return -1

        hits = []
        s, e = self.amfi_text
        for off in range(s, e - 4, 4):
            d0 = self._disas_at(off)
            if not d0 or d0[0].mnemonic != "pacibsp":
                continue

            func_end = min(off + 0x200, e)
            for p in range(off + 4, func_end, 4):
                dp = self._disas_at(p)
                if dp and dp[0].mnemonic == "pacibsp":
                    func_end = p
                    break

            insns = []
            for p in range(off, func_end, 4):
                d = self._disas_at(p)
                if not d:
                    break
                insns.append(d[0])

            i1 = _find_after(
                insns, 0, lambda x: x.mnemonic == "mov" and x.op_str == "x19, x2"
            )
            if i1 < 0:
                continue
            i2 = _find_after(
                insns,
                i1 + 1,
                lambda x: x.mnemonic == "stp" and x.op_str.startswith("xzr, xzr, [sp"),
            )
            if i2 < 0:
                continue
            i3 = _find_after(
                insns, i2 + 1, lambda x: x.mnemonic == "mov" and x.op_str == "x2, sp"
            )
            if i3 < 0:
                continue
            i4 = _find_after(insns, i3 + 1, lambda x: x.mnemonic == "bl")
            if i4 < 0:
                continue
            i5 = _find_after(
                insns, i4 + 1, lambda x: x.mnemonic == "mov" and x.op_str == "x20, x0"
            )
            if i5 < 0:
                continue
            i6 = _find_after(
                insns,
                i5 + 1,
                lambda x: x.mnemonic == "cbnz" and x.op_str.startswith("w0,"),
            )
            if i6 < 0:
                continue
            i7 = _find_after(
                insns,
                i6 + 1,
                lambda x: x.mnemonic == "cbz" and x.op_str.startswith("x19,"),
            )
            if i7 < 0:
                continue

            hits.append(off)

        if len(hits) != 1:
            self._log(f"  [-] expected 1 AMFI trustcache body hit, found {len(hits)}")
            return False

        func_start = hits[0]
        self.emit(func_start, MOV_X0_1, "mov x0,#1 [AMFIIsCDHashInTrustCache]")
        self.emit(func_start + 4, CBZ_X2_8, "cbz x2,+8 [AMFIIsCDHashInTrustCache]")
        self.emit(func_start + 8, STR_X0_X2, "str x0,[x2] [AMFIIsCDHashInTrustCache]")
        self.emit(func_start + 12, RET, "ret [AMFIIsCDHashInTrustCache]")
        return True

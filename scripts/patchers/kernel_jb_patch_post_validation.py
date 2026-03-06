"""Mixin: KernelJBPatchPostValidationMixin."""

from .kernel_jb_base import ARM64_OP_REG, ARM64_OP_IMM, ARM64_REG_W0, CMP_W0_W0


class KernelJBPatchPostValidationMixin:
    def patch_post_validation_additional(self):
        """Rewrite the SHA256-only reject compare in AMFI's post-validation path.

        Runtime reveal is string-anchored only: use the
        `"AMFI: code signature validation failed"` xref, recover the caller,
        then recover the BL target whose body contains the unique
        `cmp w0,#imm ; b.ne` reject gate reached immediately after a BL.
        No broad AMFI-text fallback is kept.
        """
        self._log("\n[JB] postValidation additional: cmp w0,w0")

        str_off = self.find_string(b"AMFI: code signature validation failed")
        if str_off < 0:
            self._log("  [-] string not found")
            return False

        refs = self.find_string_refs(str_off, *self.amfi_text)
        if not refs:
            refs = self.find_string_refs(str_off)
        if not refs:
            self._log("  [-] no code refs")
            return False

        hits = []
        seen = set()
        for ref_off, _, _ in refs:
            caller_start = self.find_function_start(ref_off)
            if caller_start < 0 or caller_start in seen:
                continue
            seen.add(caller_start)

            func_end = self._find_func_end(caller_start, 0x2000)
            bl_targets = set()
            for scan in range(caller_start, func_end, 4):
                target = self._is_bl(scan)
                if target >= 0:
                    bl_targets.add(target)

            for target in sorted(bl_targets):
                if not (self.amfi_text[0] <= target < self.amfi_text[1]):
                    continue
                callee_end = self._find_func_end(target, 0x200)
                for off in range(target, callee_end, 4):
                    d = self._disas_at(off, 2)
                    if len(d) < 2:
                        continue
                    i0, i1 = d[0], d[1]
                    if i0.mnemonic != "cmp" or i1.mnemonic != "b.ne":
                        continue
                    ops = i0.operands
                    if len(ops) < 2:
                        continue
                    if ops[0].type != ARM64_OP_REG or ops[0].reg != ARM64_REG_W0:
                        continue
                    if ops[1].type != ARM64_OP_IMM:
                        continue
                    has_bl = False
                    for back in range(off - 4, max(off - 12, target), -4):
                        if self._is_bl(back) >= 0:
                            has_bl = True
                            break
                    if has_bl:
                        hits.append(off)

        hits = sorted(set(hits))
        if len(hits) != 1:
            self._log(f"  [-] expected 1 postValidation compare site, found {len(hits)}")
            return False

        self.emit(hits[0], CMP_W0_W0, "cmp w0,w0 [postValidation additional]")
        return True

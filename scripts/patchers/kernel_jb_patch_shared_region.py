"""Mixin: KernelJBPatchSharedRegionMixin."""

from .kernel_jb_base import ARM64_OP_IMM, ARM64_OP_REG, CMP_X0_X0


class KernelJBPatchSharedRegionMixin:
    def patch_shared_region_map(self):
        """Match the upstream root-vs-preboot gate in shared_region setup.

        Anchor class: string anchor. Resolve the setup helper from the in-image
        `/private/preboot/Cryptexes` string, then patch the *first* compare that
        guards the preboot lookup block:

            cmp mount_reg, root_mount_reg
            b.eq skip_lookup
            ... prepare PREBOOT_CRYPTEX_PATH ...

        This intentionally matches `/Users/qaq/Desktop/patch_fw.py` by forcing
        the initial root-mount comparison to compare equal, rather than only
        patching the later fallback compare against the looked-up preboot mount.
        """
        self._log("\n[JB] _shared_region_map_and_slide_setup: upstream cmp x0,x0")

        foff = self._find_func_by_string(b"/private/preboot/Cryptexes", self.kern_text)
        if foff < 0:
            self._log("  [-] function not found via Cryptexes anchor")
            return False

        func_end = self._find_func_end(foff, 0x2000)
        str_off = self.find_string(b"/private/preboot/Cryptexes")
        if str_off < 0:
            self._log("  [-] Cryptexes string not found")
            return False

        refs = self.find_string_refs(str_off, foff, func_end)
        hits = []
        for adrp_off, _, _ in refs:
            patch_off = self._find_upstream_root_mount_cmp(foff, adrp_off)
            if patch_off is not None:
                hits.append(patch_off)

        if len(hits) != 1:
            self._log("  [-] upstream root-vs-preboot cmp gate not found uniquely")
            return False

        self.emit(
            hits[0], CMP_X0_X0, "cmp x0,x0 [_shared_region_map_and_slide_setup]"
        )
        return True

    def _find_upstream_root_mount_cmp(self, func_start, str_ref_off):
        scan_start = max(func_start, str_ref_off - 0x24)
        scan_end = min(str_ref_off, scan_start + 0x24)
        for off in range(scan_start, scan_end, 4):
            d = self._disas_at(off, 3)
            if len(d) < 3:
                continue
            cmp_insn, beq_insn, next_insn = d[0], d[1], d[2]
            if cmp_insn.mnemonic != "cmp" or beq_insn.mnemonic != "b.eq":
                continue
            if len(cmp_insn.operands) != 2 or len(beq_insn.operands) != 1:
                continue
            if cmp_insn.operands[0].type != ARM64_OP_REG or cmp_insn.operands[1].type != ARM64_OP_REG:
                continue
            if beq_insn.operands[0].type != ARM64_OP_IMM or beq_insn.operands[0].imm <= beq_insn.address:
                continue
            if next_insn.mnemonic != "str" or "xzr" not in next_insn.op_str:
                continue
            return cmp_insn.address
        return None

"""Mixin: KernelJBPatchSpawnPersonaMixin."""

from .kernel_jb_base import ARM64_OP_IMM, ARM64_OP_MEM, ARM64_OP_REG, NOP


class KernelJBPatchSpawnPersonaMixin:
    def patch_spawn_validate_persona(self):
        """Restore the upstream dual-CBZ bypass in the persona helper.

        Preferred design target is `/Users/qaq/Desktop/patch_fw.py`, which NOPs
        two sibling `cbz w?, deny` guards in the small helper reached from the
        entitlement-string-driven spawn policy wrapper.

        Runtime design intentionally avoids unstable symbols:
        1. recover the outer spawn policy function from the embedded
           `com.apple.private.spawn-panic-crash-behavior` string,
        2. enumerate its local BL callees,
        3. choose the unique small callee whose local CFG matches the upstream
           helper shape (`ldr [arg,#8] ; cbz deny ; ldr [arg,#0xc] ; cbz deny`),
        4. NOP both `cbz` guards at the upstream sites.
        """
        self._log("\n[JB] _spawn_validate_persona: upstream dual-CBZ bypass")

        anchor_func = self._find_func_by_string(
            b"com.apple.private.spawn-panic-crash-behavior", self.kern_text
        )
        if anchor_func < 0:
            self._log("  [-] spawn entitlement anchor not found")
            return False

        anchor_end = self._find_func_end(anchor_func, 0x4000)
        sites = self._find_upstream_persona_cbz_sites(anchor_func, anchor_end)
        if sites is None:
            self._log("  [-] upstream persona helper not found from string anchor")
            return False

        first_cbz, second_cbz = sites
        self.emit(first_cbz, NOP, "NOP [_spawn_validate_persona pid-slot guard]")
        self.emit(second_cbz, NOP, "NOP [_spawn_validate_persona persona-slot guard]")
        return True

    def _find_upstream_persona_cbz_sites(self, anchor_start, anchor_end):
        matches = []
        seen = set()
        for off in range(anchor_start, anchor_end, 4):
            target = self._is_bl(off)
            if target < 0 or target in seen:
                continue
            if not (self.kern_text[0] <= target < self.kern_text[1]):
                continue
            seen.add(target)
            func_end = self._find_func_end(target, 0x400)
            sites = self._match_persona_helper(target, func_end)
            if sites is not None:
                matches.append(sites)

        if len(matches) == 1:
            return matches[0]
        if matches:
            self._log(
                "  [-] ambiguous persona helper candidates: "
                + ", ".join(f"0x{a:X}/0x{b:X}" for a, b in matches)
            )
        return None

    def _match_persona_helper(self, start, end):
        hits = []
        for off in range(start, end - 0x14, 4):
            d = self._disas_at(off, 6)
            if len(d) < 6:
                continue
            i0, i1, i2, i3, i4, i5 = d[:6]
            if not self._is_ldr_mem(i0, disp=8):
                continue
            if not self._is_cbz_w_same_reg(i1, i0.operands[0].reg):
                continue
            if not self._is_ldr_mem_same_base(i2, i0.operands[1].mem.base, disp=0xC):
                continue
            if not self._is_cbz_w_same_reg(i3, i2.operands[0].reg):
                continue
            deny_target = i1.operands[1].imm
            if i3.operands[1].imm != deny_target:
                continue
            if not self._looks_like_errno_return(deny_target, 1):
                continue
            if not self._is_mov_x_imm_zero(i4):
                continue
            if not self._is_ldr_mem(i5, disp=0x490):
                continue
            hits.append((i1.address, i3.address))

        if len(hits) == 1:
            return hits[0]
        return None

    def _looks_like_errno_return(self, target, errno_value):
        d = self._disas_at(target, 2)
        return len(d) >= 1 and self._is_mov_w_imm_value(d[0], errno_value)

    def _is_ldr_mem(self, insn, disp):
        if insn.mnemonic != "ldr" or len(insn.operands) < 2:
            return False
        dst, src = insn.operands[:2]
        return dst.type == ARM64_OP_REG and src.type == ARM64_OP_MEM and src.mem.disp == disp

    def _is_ldr_mem_same_base(self, insn, base_reg, disp):
        return self._is_ldr_mem(insn, disp) and insn.operands[1].mem.base == base_reg

    def _is_cbz_w_same_reg(self, insn, reg):
        if insn.mnemonic != "cbz" or len(insn.operands) != 2:
            return False
        op0, op1 = insn.operands
        return (
            op0.type == ARM64_OP_REG
            and op0.reg == reg
            and op1.type == ARM64_OP_IMM
            and insn.reg_name(op0.reg).startswith("w")
        )

    def _is_mov_x_imm_zero(self, insn):
        if insn.mnemonic != "mov" or len(insn.operands) != 2:
            return False
        dst, src = insn.operands
        return (
            dst.type == ARM64_OP_REG
            and src.type == ARM64_OP_IMM
            and src.imm == 0
            and insn.reg_name(dst.reg).startswith("x")
        )

    def _is_mov_w_imm_value(self, insn, imm):
        if insn.mnemonic != "mov" or len(insn.operands) != 2:
            return False
        dst, src = insn.operands
        return (
            dst.type == ARM64_OP_REG
            and src.type == ARM64_OP_IMM
            and src.imm == imm
            and insn.reg_name(dst.reg).startswith("w")
        )

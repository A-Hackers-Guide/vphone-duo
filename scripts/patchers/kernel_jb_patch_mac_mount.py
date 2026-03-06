"""Mixin: KernelJBPatchMacMountMixin."""

from .kernel_asm import _cs
from .kernel_jb_base import ARM64_OP_IMM, ARM64_OP_MEM, ARM64_OP_REG, asm


class KernelJBPatchMacMountMixin:
    def patch_mac_mount(self):
        """Apply the upstream twin bypasses in the mount-role wrapper.

        Preferred design target is `/Users/qaq/Desktop/patch_fw.py`, which
        patches two sites in the wrapper that decides whether execution can
        continue into `mount_common()`:

        - `tbnz wFlags, #5, deny` -> `nop`
        - `ldrb w8, [xTmp, #1]` -> `mov x8, xzr`

        Runtime design avoids unstable symbols by:
        1. recovering `mount_common` from the in-image `"mount_common()"`
           string,
        2. scanning only a bounded neighborhood for local callers of that
           recovered function,
        3. selecting the unique caller that contains both upstream gates.
        """
        self._log("\n[JB] ___mac_mount: upstream twin bypass")

        mount_common = self._find_func_by_string(b"mount_common()", self.kern_text)
        if mount_common < 0:
            self._log("  [-] mount_common anchor function not found")
            return False

        search_start = max(self.kern_text[0], mount_common - 0x5000)
        search_end = min(self.kern_text[1], mount_common + 0x5000)
        candidates = {}
        for off in range(search_start, search_end, 4):
            target = self._is_bl(off)
            if target != mount_common:
                continue
            caller = self.find_function_start(off)
            if caller < 0 or caller == mount_common or caller in candidates:
                continue
            caller_end = self._find_func_end(caller, 0x1200)
            sites = self._match_upstream_mount_wrapper(caller, caller_end, mount_common)
            if sites is not None:
                candidates[caller] = sites

        if len(candidates) != 1:
            self._log(f"  [-] expected 1 upstream mac_mount candidate, found {len(candidates)}")
            return False

        branch_off, mov_off = next(iter(candidates.values()))
        self.emit(branch_off, asm("nop"), "NOP [___mac_mount upstream flag gate]")
        self.emit(mov_off, asm("mov x8, xzr"), "mov x8,xzr [___mac_mount upstream state clear]")
        return True

    def _match_upstream_mount_wrapper(self, start, end, mount_common):
        call_sites = []
        for off in range(start, end, 4):
            if self._is_bl(off) == mount_common:
                call_sites.append(off)
        if not call_sites:
            return None

        flag_gate = self._find_flag_gate(start, end)
        if flag_gate is None:
            return None

        state_gate = self._find_state_gate(start, end, call_sites)
        if state_gate is None:
            return None

        return (flag_gate, state_gate)

    def _find_flag_gate(self, start, end):
        hits = []
        for off in range(start, end - 4, 4):
            d = self._disas_at(off)
            if not d:
                continue
            insn = d[0]
            if insn.mnemonic != "tbnz" or not self._is_bit_branch(insn, "w", 5):
                continue
            target = insn.operands[2].imm
            if not (start <= target < end):
                continue
            td = self._disas_at(target)
            if not td or not self._is_mov_w_imm_value(td[0], 1):
                continue
            hits.append(off)
        if len(hits) == 1:
            return hits[0]
        return None

    def _find_state_gate(self, start, end, call_sites):
        hits = []
        for off in range(start, end - 8, 4):
            d = self._disas_at(off, 3)
            if len(d) < 3:
                continue
            i0, i1, i2 = d
            if not self._is_add_x_imm(i0, 0x70):
                continue
            if not self._is_ldrb_same_base_plus_1(i1, i0.operands[0].reg):
                continue
            if i2.mnemonic != "tbz" or not self._is_bit_branch(i2, self._reg_name(i1.operands[0].reg), 6):
                continue
            target = i2.operands[2].imm
            if not any(target <= call_off <= target + 0x80 for call_off in call_sites):
                continue
            hits.append(i1.address)
        if len(hits) == 1:
            return hits[0]
        return None

    def _is_bit_branch(self, insn, reg_prefix_or_name, bit):
        if len(insn.operands) != 3:
            return False
        reg_op, bit_op, target_op = insn.operands
        if reg_op.type != ARM64_OP_REG or bit_op.type != ARM64_OP_IMM or target_op.type != ARM64_OP_IMM:
            return False
        reg_name = self._reg_name(reg_op.reg)
        if len(reg_prefix_or_name) == 1:
            if not reg_name.startswith(reg_prefix_or_name):
                return False
        elif reg_name != reg_prefix_or_name:
            return False
        return bit_op.imm == bit

    def _is_mov_w_imm_value(self, insn, imm):
        if insn.mnemonic != "mov" or len(insn.operands) != 2:
            return False
        dst, src = insn.operands
        return (
            dst.type == ARM64_OP_REG
            and src.type == ARM64_OP_IMM
            and self._reg_name(dst.reg).startswith("w")
            and src.imm == imm
        )

    def _is_add_x_imm(self, insn, imm):
        if insn.mnemonic != "add" or len(insn.operands) != 3:
            return False
        dst, src, imm_op = insn.operands
        return (
            dst.type == ARM64_OP_REG
            and src.type == ARM64_OP_REG
            and imm_op.type == ARM64_OP_IMM
            and self._reg_name(dst.reg).startswith("x")
            and self._reg_name(src.reg).startswith("x")
            and imm_op.imm == imm
        )

    def _is_ldrb_same_base_plus_1(self, insn, base_reg):
        if insn.mnemonic != "ldrb" or len(insn.operands) < 2:
            return False
        dst, src = insn.operands[:2]
        return (
            dst.type == ARM64_OP_REG
            and src.type == ARM64_OP_MEM
            and src.mem.base == base_reg
            and src.mem.disp == 1
            and self._reg_name(dst.reg).startswith("w")
        )

    def _reg_name(self, reg):
        return _cs.reg_name(reg)

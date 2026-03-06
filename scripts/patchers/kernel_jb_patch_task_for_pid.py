"""Mixin: KernelJBPatchTaskForPidMixin."""

from .kernel_asm import _cs
from .kernel_jb_base import ARM64_OP_IMM, ARM64_OP_MEM, ARM64_OP_REG, NOP


class KernelJBPatchTaskForPidMixin:
    def patch_task_for_pid(self):
        """NOP the upstream early `pid == 0` reject gate in `task_for_pid`.

        Preferred design target is `/Users/qaq/Desktop/patch_fw.py`, which
        patches the early `cbz wPid, fail` gate before `port_name_to_task()`.

        Anchor class: heuristic.

        There is no stable direct `task_for_pid` symbol path on the stripped
        kernels, so the runtime reveal first recovers the enclosing function via
        the in-function string `proc_ro_ref_task`, then scans only that function
        and looks for the unique upstream local shape:

            ldr wPid, [xArgs, #8]
            ldr xTaskPtr, [xArgs, #0x10]
            ...
            cbz wPid, fail
            mov w1, #0
            mov w2, #0
            mov w3, #0
            mov x4, #0
            bl  port_name_to_task-like helper
            cbz x0, fail
        """
        self._log("\n[JB] _task_for_pid: upstream pid==0 gate NOP")

        func_start = self._find_func_by_string(b"proc_ro_ref_task", self.kern_text)
        if func_start < 0:
            self._log("  [-] task_for_pid anchor function not found")
            return False
        search_end = min(self.kern_text[1], func_start + 0x800)

        hits = []
        for off in range(func_start, search_end - 0x18, 4):
            d0 = self._disas_at(off)
            if not d0 or d0[0].mnemonic != "cbz":
                continue
            hit = self._match_upstream_task_for_pid_gate(off, func_start)
            if hit is not None:
                hits.append(hit)

        if len(hits) != 1:
            self._log(f"  [-] expected 1 upstream task_for_pid candidate, found {len(hits)}")
            return False

        self.emit(hits[0], NOP, "NOP [_task_for_pid pid==0 gate]")
        return True

    def _match_upstream_task_for_pid_gate(self, off, func_start):
        d = self._disas_at(off, 7)
        if len(d) < 7:
            return None
        cbz_pid, mov1, mov2, mov3, mov4, bl_insn, cbz_ret = d
        if cbz_pid.mnemonic != "cbz" or len(cbz_pid.operands) != 2:
            return None
        if cbz_pid.operands[0].type != ARM64_OP_REG or cbz_pid.operands[1].type != ARM64_OP_IMM:
            return None

        if not self._is_mov_imm_zero(mov1, "w1"):
            return None
        if not self._is_mov_imm_zero(mov2, "w2"):
            return None
        if not self._is_mov_imm_zero(mov3, "w3"):
            return None
        if not self._is_mov_imm_zero(mov4, "x4"):
            return None
        if bl_insn.mnemonic != "bl":
            return None
        if cbz_ret.mnemonic != "cbz" or len(cbz_ret.operands) != 2:
            return None
        if cbz_ret.operands[0].type != ARM64_OP_REG or cbz_ret.reg_name(cbz_ret.operands[0].reg) != "x0":
            return None
        fail_target = cbz_pid.operands[1].imm
        if cbz_ret.operands[1].type != ARM64_OP_IMM or cbz_ret.operands[1].imm != fail_target:
            return None

        pid_load = None
        taskptr_load = None
        for prev_off in range(max(func_start, off - 0x18), off, 4):
            prev_d = self._disas_at(prev_off)
            if not prev_d:
                continue
            prev = prev_d[0]
            if pid_load is None and self._is_w_ldr_from_x_imm(prev, 8):
                pid_load = prev
                continue
            if taskptr_load is None and self._is_x_ldr_from_x_imm(prev, 0x10):
                taskptr_load = prev
        if pid_load is None or taskptr_load is None:
            return None
        if cbz_pid.operands[0].reg != pid_load.operands[0].reg:
            return None
        return cbz_pid.address

    def _is_mov_imm_zero(self, insn, dst_name):
        if insn.mnemonic != "mov" or len(insn.operands) != 2:
            return False
        dst, src = insn.operands
        return (
            dst.type == ARM64_OP_REG
            and insn.reg_name(dst.reg) == dst_name
            and src.type == ARM64_OP_IMM
            and src.imm == 0
        )

    def _is_w_ldr_from_x_imm(self, insn, imm):
        if insn.mnemonic != "ldr" or len(insn.operands) < 2:
            return False
        dst, src = insn.operands[:2]
        return (
            dst.type == ARM64_OP_REG
            and insn.reg_name(dst.reg).startswith("w")
            and src.type == ARM64_OP_MEM
            and insn.reg_name(src.mem.base).startswith("x")
            and src.mem.disp == imm
        )

    def _is_x_ldr_from_x_imm(self, insn, imm):
        if insn.mnemonic != "ldr" or len(insn.operands) < 2:
            return False
        dst, src = insn.operands[:2]
        return (
            dst.type == ARM64_OP_REG
            and insn.reg_name(dst.reg).startswith("x")
            and src.type == ARM64_OP_MEM
            and insn.reg_name(src.mem.base).startswith("x")
            and src.mem.disp == imm
        )

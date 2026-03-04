"""Mixin: debugger enablement patch."""

from capstone.arm64_const import ARM64_OP_REG, ARM64_REG_X8

from .kernel_asm import MOV_X0_1, RET, _rd32, _rd64


class KernelPatchDebuggerMixin:
    def patch_PE_i_can_has_debugger(self):
        """Patches 6-7: mov x0,#1; ret at _PE_i_can_has_debugger."""
        self._log("\n[6-7] _PE_i_can_has_debugger: stub with mov x0,#1; ret")

        # Strategy 1: find symbol name in __LINKEDIT and parse nearby VA
        str_off = self.find_string(b"\x00_PE_i_can_has_debugger\x00")
        if str_off < 0:
            str_off = self.find_string(b"PE_i_can_has_debugger")
        if str_off >= 0:
            linkedit = None
            for name, vmaddr, fileoff, filesize, _ in self.all_segments:
                if name == "__LINKEDIT":
                    linkedit = (fileoff, fileoff + filesize)
            if linkedit and linkedit[0] <= str_off < linkedit[1]:
                name_end = self.raw.find(b"\x00", str_off + 1)
                if name_end > 0:
                    for probe in range(name_end + 1, min(name_end + 32, self.size - 7)):
                        val = _rd64(self.raw, probe)
                        func_foff = val - self.base_va
                        if self.kern_text[0] <= func_foff < self.kern_text[1]:
                            first_insn = _rd32(self.raw, func_foff)
                            if first_insn != 0 and first_insn != 0xD503201F:
                                self.emit(
                                    func_foff,
                                    MOV_X0_1,
                                    "mov x0,#1 [_PE_i_can_has_debugger]",
                                )
                                self.emit(
                                    func_foff + 4, RET, "ret [_PE_i_can_has_debugger]"
                                )
                                return True

        # Strategy 2: code pattern — function starts with ADRP x8,
        # preceded by a function boundary, has many BL callers,
        # and reads a 32-bit (w-register) value within first few instructions.
        self._log("  [*] trying code pattern search...")

        # Determine kernel-only __text range from fileset entries if available
        kern_text_start, kern_text_end = self._get_kernel_text_range()

        best_off = -1
        best_callers = 0
        for off in range(kern_text_start, kern_text_end - 12, 4):
            dis = self._disas_at(off)
            if not dis or dis[0].mnemonic != "adrp":
                continue
            # Must target x8
            if dis[0].operands[0].reg != ARM64_REG_X8:
                continue
            # Must be preceded by function boundary
            if off >= 4:
                prev = _rd32(self.raw, off - 4)
                if not self._is_func_boundary(prev):
                    continue
            # Must read a w-register (32-bit) from [x8, #imm] within first 6 instructions
            has_w_load = False
            for k in range(1, 7):
                if off + k * 4 >= self.size:
                    break
                dk = self._disas_at(off + k * 4)
                if (
                    dk
                    and dk[0].mnemonic == "ldr"
                    and dk[0].op_str.startswith("w")
                    and "x8" in dk[0].op_str
                ):
                    has_w_load = True
                    break
            if not has_w_load:
                continue
            # Count callers — _PE_i_can_has_debugger has ~80-200 callers
            # (widely used but not a basic kernel primitive)
            n_callers = len(self.bl_callers.get(off, []))
            if 50 <= n_callers <= 250 and n_callers > best_callers:
                best_callers = n_callers
                best_off = off

        if best_off >= 0:
            self._log(
                f"  [+] code pattern match at 0x{best_off:X} ({best_callers} callers)"
            )
            self.emit(best_off, MOV_X0_1, "mov x0,#1 [_PE_i_can_has_debugger]")
            self.emit(best_off + 4, RET, "ret [_PE_i_can_has_debugger]")
            return True

        self._log("  [-] function not found")
        return False

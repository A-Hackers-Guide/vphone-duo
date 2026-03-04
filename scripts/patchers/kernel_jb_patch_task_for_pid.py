"""Mixin: KernelJBPatchTaskForPidMixin."""

from .kernel_jb_base import NOP


class KernelJBPatchTaskForPidMixin:
    def patch_task_for_pid(self):
        """NOP proc_ro security policy copy in _task_for_pid.

        Pattern: _task_for_pid is a Mach trap handler (0 BL callers) with:
          - 2x ldadda (proc reference counting)
          - 2x ldr wN,[xN,#0x490]; str wN,[xN,#0xc] (proc_ro security copy)
          - movk xN, #0xc8a2, lsl #48 (PAC discriminator)
          - BL to a non-panic function with >500 callers (proc_find etc.)
        NOP the second ldr wN,[xN,#0x490] (the target process security copy).
        """
        self._log("\n[JB] _task_for_pid: NOP")

        # Try symbol first
        foff = self._resolve_symbol("_task_for_pid")
        if foff >= 0:
            func_end = self._find_func_end(foff, 0x800)
            patch_off = self._find_second_ldr490(foff, func_end)
            if patch_off:
                self.emit(patch_off, NOP, "NOP [_task_for_pid proc_ro copy]")
                return True

        # Pattern search: scan kern_text for functions matching the profile
        ks, ke = self.kern_text
        off = ks
        while off < ke - 4:
            d = self._disas_at(off)
            if not d or d[0].mnemonic != "pacibsp":
                off += 4
                continue
            func_start = off
            func_end = self._find_func_end(func_start, 0x1000)

            # Quick filter: skip functions with BL callers (Mach trap = indirect)
            if self.bl_callers.get(func_start, []):
                off = func_end
                continue

            ldadda_count = 0
            ldr490_count = 0
            ldr490_offs = []
            has_movk_c8a2 = False
            has_high_caller_bl = False

            for o in range(func_start, func_end, 4):
                d = self._disas_at(o)
                if not d:
                    continue
                i = d[0]
                if i.mnemonic == "ldadda":
                    ldadda_count += 1
                elif (
                    i.mnemonic == "ldr"
                    and "#0x490" in i.op_str
                    and i.op_str.startswith("w")
                ):
                    d2 = self._disas_at(o + 4)
                    if (
                        d2
                        and d2[0].mnemonic == "str"
                        and "#0xc" in d2[0].op_str
                        and d2[0].op_str.startswith("w")
                    ):
                        ldr490_count += 1
                        ldr490_offs.append(o)
                elif i.mnemonic == "movk" and "#0xc8a2" in i.op_str:
                    has_movk_c8a2 = True
                elif i.mnemonic == "bl":
                    target = i.operands[0].imm
                    n_callers = len(self.bl_callers.get(target, []))
                    # >500 but <8000 excludes _panic (typically 8000+)
                    if 500 < n_callers < 8000:
                        has_high_caller_bl = True

            if (
                ldadda_count >= 2
                and ldr490_count >= 2
                and has_movk_c8a2
                and has_high_caller_bl
            ):
                patch_off = ldr490_offs[1]  # NOP the second occurrence
                self._log(
                    f"  [+] _task_for_pid at 0x{func_start:X}, patch at 0x{patch_off:X}"
                )
                self.emit(patch_off, NOP, "NOP [_task_for_pid proc_ro copy]")
                return True

            off = func_end

        self._log("  [-] function not found")
        return False

    def _find_second_ldr490(self, start, end):
        """Find the second ldr wN,[xN,#0x490]+str wN,[xN,#0xc] in range."""
        count = 0
        for off in range(start, end - 4, 4):
            d = self._disas_at(off)
            if not d or d[0].mnemonic != "ldr":
                continue
            if "#0x490" not in d[0].op_str or not d[0].op_str.startswith("w"):
                continue
            d2 = self._disas_at(off + 4)
            if (
                d2
                and d2[0].mnemonic == "str"
                and "#0xc" in d2[0].op_str
                and d2[0].op_str.startswith("w")
            ):
                count += 1
                if count == 2:
                    return off
        return None

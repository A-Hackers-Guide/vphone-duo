"""Mixin: KernelJBPatchAmfiExecveMixin."""

from .kernel_jb_base import MOV_W0_0, _rd32


class KernelJBPatchAmfiExecveMixin:
    def patch_amfi_execve_kill_path(self):
        """Bypass AMFI execve kill by changing the shared kill return value.

        All kill paths in the AMFI execve hook converge on a shared epilogue
        that does ``MOV W0, #1`` (kill) then returns.  We change that single
        instruction to ``MOV W0, #0`` (allow), which converts every kill path
        to a success return without touching the rest of the function.

        Previous approach (patching early BL+CBZ/CBNZ sites) was incorrect:
        those are vnode-type precondition assertions, not the actual kill
        checks.  Replacing BL with MOV X0,#0 triggered the CBZ → panic.
        """
        self._log("\n[JB] AMFI execve kill path: shared MOV W0,#1 → MOV W0,#0")

        str_off = self.find_string(b"AMFI: hook..execve() killing")
        if str_off < 0:
            str_off = self.find_string(b"execve() killing")
        if str_off < 0:
            self._log("  [-] execve kill log string not found")
            return False

        refs = self.find_string_refs(str_off, *self.kern_text)
        if not refs:
            refs = self.find_string_refs(str_off)
        if not refs:
            self._log("  [-] no refs to execve kill log string")
            return False

        patched = False
        seen_funcs = set()
        for adrp_off, _, _ in refs:
            func_start = self.find_function_start(adrp_off)
            if func_start < 0 or func_start in seen_funcs:
                continue
            seen_funcs.add(func_start)

            func_end = min(func_start + 0x800, self.kern_text[1])
            for p in range(func_start + 4, func_end, 4):
                d = self._disas_at(p)
                if d and d[0].mnemonic == "pacibsp":
                    func_end = p
                    break

            # Scan backward from function end for MOV W0, #1 (0x52800020)
            # followed by LDP x29, x30 (epilogue start).
            MOV_W0_1_ENC = 0x52800020
            target_off = -1
            for off in range(func_end - 8, func_start, -4):
                if _rd32(self.raw, off) != MOV_W0_1_ENC:
                    continue
                # Verify next instruction is LDP x29, x30, [sp, #imm]
                d1 = self._disas_at(off + 4)
                if not d1:
                    continue
                i1 = d1[0]
                if i1.mnemonic == "ldp" and "x29, x30" in i1.op_str:
                    target_off = off
                    break

            if target_off < 0:
                self._log(
                    f"  [-] MOV W0,#1 + epilogue not found in "
                    f"func 0x{func_start:X}"
                )
                continue

            self.emit(
                target_off,
                MOV_W0_0,
                "mov w0,#0 [AMFI kill return → allow]",
            )
            self._log(
                f"  [+] Patched kill return at 0x{target_off:X} "
                f"(func 0x{func_start:X})"
            )
            patched = True
            break

        if not patched:
            self._log("  [-] AMFI execve kill return not found")
        return patched

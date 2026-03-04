"""Mixin: KernelJBPatchAmfiExecveMixin."""

from .kernel_jb_base import MOV_X0_0


class KernelJBPatchAmfiExecveMixin:
    def patch_amfi_execve_kill_path(self):
        """Bypass AMFI execve kill helpers (string xref -> function local pair)."""
        self._log("\n[JB] AMFI execve kill path: BL -> mov x0,#0 (2 sites)")

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

            early_window_end = min(func_start + 0x120, func_end)
            hits = []
            for off in range(func_start, early_window_end - 4, 4):
                d0 = self._disas_at(off)
                d1 = self._disas_at(off + 4)
                if not d0 or not d1:
                    continue
                i0, i1 = d0[0], d1[0]
                if i0.mnemonic != "bl":
                    continue
                if i1.mnemonic in ("cbz", "cbnz") and i1.op_str.startswith("w0,"):
                    hits.append(off)

            if len(hits) != 2:
                self._log(
                    f"  [-] execve helper at 0x{func_start:X}: "
                    f"expected 2 early BL+W0-branch sites, found {len(hits)}"
                )
                continue

            self.emit(hits[0], MOV_X0_0, "mov x0,#0 [AMFI execve helper A]")
            self.emit(hits[1], MOV_X0_0, "mov x0,#0 [AMFI execve helper B]")
            patched = True
            break

        if not patched:
            self._log("  [-] AMFI execve helper patch sites not found")
        return patched

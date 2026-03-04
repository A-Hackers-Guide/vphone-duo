"""Mixin: launch constraints patch."""

from .kernel_asm import MOV_W0_0, RET


class KernelPatchLaunchConstraintsMixin:
    def patch_proc_check_launch_constraints(self):
        """Patches 4-5: mov w0,#0; ret at _proc_check_launch_constraints start.

        The AMFI function does NOT reference the symbol name string
        '_proc_check_launch_constraints' — only the kernel wrapper does.
        Instead, use 'AMFI: Validation Category info' which IS referenced
        from the actual AMFI function.
        """
        self._log("\n[4-5] _proc_check_launch_constraints: stub with mov w0,#0; ret")

        str_off = self.find_string(b"AMFI: Validation Category info")
        if str_off < 0:
            self._log("  [-] 'AMFI: Validation Category info' string not found")
            return False

        refs = self.find_string_refs(str_off, *self.amfi_text)
        if not refs:
            self._log("  [-] no code refs in AMFI")
            return False

        for adrp_off, add_off, _ in refs:
            func_start = self.find_function_start(adrp_off)
            if func_start < 0:
                continue
            self.emit(
                func_start, MOV_W0_0, "mov w0,#0 [_proc_check_launch_constraints]"
            )
            self.emit(func_start + 4, RET, "ret [_proc_check_launch_constraints]")
            return True

        self._log("  [-] function start not found")
        return False

"""Mixin: KernelJBPatchProcPidinfoMixin."""

from .kernel_jb_base import NOP


class KernelJBPatchProcPidinfoMixin:
    def patch_proc_pidinfo(self):
        """Bypass the two early pid-0/proc-null guards in proc_pidinfo.

        Reveal from the shared `_proc_info` switch-table anchor, then match the
        precise early shape used by upstream PCC 26.1:
            ldr x0, [x0,#0x18]
            cbz x0, fail
            bl ...
            cbz/cbnz wN, fail
        Patch only those two guards.
        """
        self._log("\n[JB] _proc_pidinfo: NOP pid-0 guard (2 sites)")

        proc_info_func, _ = self._find_proc_info_anchor()
        if proc_info_func < 0:
            self._log("  [-] _proc_info function not found")
            return False

        first_guard = None
        second_guard = None
        prologue_end = min(proc_info_func + 0x80, self.size)
        for off in range(proc_info_func, prologue_end - 0x10, 4):
            d0 = self._disas_at(off)
            d1 = self._disas_at(off + 4)
            d2 = self._disas_at(off + 8)
            d3 = self._disas_at(off + 12)
            if not d0 or not d1 or not d2 or not d3:
                continue
            i0, i1, i2, i3 = d0[0], d1[0], d2[0], d3[0]
            if (
                i0.mnemonic == 'ldr' and i0.op_str.startswith('x0, [x0, #0x18]') and
                i1.mnemonic == 'cbz' and i1.op_str.startswith('x0, ') and
                i2.mnemonic == 'bl' and
                i3.mnemonic in ('cbz', 'cbnz') and i3.op_str.startswith('w')
            ):
                first_guard = off + 4
                second_guard = off + 12
                break

        if first_guard is None or second_guard is None:
            self._log('  [-] precise proc_pidinfo guard pair not found')
            return False

        self.emit(first_guard, NOP, 'NOP [_proc_pidinfo pid-0 guard A]')
        self.emit(second_guard, NOP, 'NOP [_proc_pidinfo pid-0 guard B]')
        return True

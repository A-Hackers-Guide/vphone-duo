"""Mixin: KernelJBPatchNvramMixin."""

from .kernel_jb_base import NOP


class KernelJBPatchNvramMixin:
    def patch_nvram_verify_permission(self):
        """NOP the verifyPermission gate in the `krn.` key-prefix path.

        Runtime reveal is string-anchored only: enumerate code refs to `"krn."`,
        recover the containing function for each ref, then pick the unique
        `tbz/tbnz` guard immediately before that key-prefix load sequence.
        """
        self._log("\n[JB] verifyPermission (NVRAM): NOP")

        str_off = self.find_string(b"krn.")
        if str_off < 0:
            self._log("  [-] 'krn.' string not found")
            return False

        refs = self.find_string_refs(str_off)
        if not refs:
            self._log("  [-] no code refs to 'krn.'")
            return False

        hits = []
        seen = set()
        for ref_off, _, _ in refs:
            foff = self.find_function_start(ref_off)
            if foff < 0 or foff in seen:
                continue
            seen.add(foff)
            for off in range(ref_off - 4, max(foff - 4, ref_off - 0x20), -4):
                d = self._disas_at(off)
                if d and d[0].mnemonic in ('tbnz', 'tbz'):
                    hits.append(off)
                    break

        hits = sorted(set(hits))
        if len(hits) != 1:
            self._log(f"  [-] expected 1 NVRAM verifyPermission gate, found {len(hits)}")
            return False

        self.emit(hits[0], NOP, 'NOP [verifyPermission NVRAM]')
        return True

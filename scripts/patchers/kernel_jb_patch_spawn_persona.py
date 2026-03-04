"""Mixin: KernelJBPatchSpawnPersonaMixin."""

from .kernel_jb_base import NOP


class KernelJBPatchSpawnPersonaMixin:
    def patch_spawn_validate_persona(self):
        """NOP persona validation: LDR + TBNZ sites.
        Pattern: ldr wN, [xN, #0x600] (unique struct offset) followed by
        cbz wN then tbnz wN, #1 — NOP both the LDR and the TBNZ.
        """
        self._log("\n[JB] _spawn_validate_persona: NOP (2 sites)")

        # Try symbol first
        foff = self._resolve_symbol("_spawn_validate_persona")
        if foff >= 0:
            func_end = self._find_func_end(foff, 0x800)
            result = self._find_persona_pattern(foff, func_end)
            if result:
                self.emit(result[0], NOP, "NOP [_spawn_validate_persona LDR]")
                self.emit(result[1], NOP, "NOP [_spawn_validate_persona TBNZ]")
                return True

        # Pattern search: ldr wN, [xN, #0x600] ... tbnz wN, #1
        # This pattern is unique to _spawn_validate_persona
        ks, ke = self.kern_text
        for off in range(ks, ke - 0x30, 4):
            d = self._disas_at(off)
            if not d or d[0].mnemonic != "ldr":
                continue
            if "#0x600" not in d[0].op_str:
                continue
            if not d[0].op_str.startswith("w"):
                continue
            # Found LDR wN, [xN, #0x600] — look for TBNZ wN, #1 within 0x30
            for delta in range(4, 0x30, 4):
                d2 = self._disas_at(off + delta)
                if not d2:
                    continue
                if d2[0].mnemonic == "tbnz" and "#1" in d2[0].op_str:
                    # Verify it's a w-register
                    if d2[0].op_str.startswith("w"):
                        self._log(f"  [+] LDR at 0x{off:X}, TBNZ at 0x{off + delta:X}")
                        self.emit(off, NOP, "NOP [_spawn_validate_persona LDR]")
                        self.emit(
                            off + delta, NOP, "NOP [_spawn_validate_persona TBNZ]"
                        )
                        return True

        self._log("  [-] pattern not found")
        return False

    def _find_persona_pattern(self, start, end):
        """Find ldr wN,[xN,#0x600] + tbnz wN,#1 pattern. Returns (ldr_off, tbnz_off)."""
        for off in range(start, end - 0x30, 4):
            d = self._disas_at(off)
            if not d or d[0].mnemonic != "ldr":
                continue
            if "#0x600" not in d[0].op_str or not d[0].op_str.startswith("w"):
                continue
            for delta in range(4, 0x30, 4):
                d2 = self._disas_at(off + delta)
                if d2 and d2[0].mnemonic == "tbnz" and "#1" in d2[0].op_str:
                    if d2[0].op_str.startswith("w"):
                        return (off, off + delta)
        return None

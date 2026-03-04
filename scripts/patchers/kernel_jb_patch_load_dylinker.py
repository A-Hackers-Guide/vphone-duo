"""Mixin: KernelJBPatchLoadDylinkerMixin."""

from .kernel_jb_base import NOP


class KernelJBPatchLoadDylinkerMixin:
    def patch_load_dylinker(self):
        """Bypass PAC auth check in Mach-O chained fixup rebase code.

        The kernel's chained fixup pointer rebase function contains PAC
        authentication triplets: TST xN, #high; B.EQ skip; MOVK xN, #0xc8a2.
        This function has 3+ such triplets and 0 BL callers (indirect call).

        Find the function and replace the LAST TST with an unconditional
        branch to the B.EQ target (always skip PAC re-signing).
        """
        self._log("\n[JB] _load_dylinker: PAC rebase bypass")

        # Try symbol first
        foff = self._resolve_symbol("_load_dylinker")
        if foff >= 0:
            func_end = self._find_func_end(foff, 0x2000)
            result = self._find_tst_pac_triplet(foff, func_end)
            if result:
                tst_off, beq_target = result
                b_bytes = self._encode_b(tst_off, beq_target)
                if b_bytes:
                    self.emit(
                        tst_off,
                        b_bytes,
                        f"b #0x{beq_target - tst_off:X} [_load_dylinker]",
                    )
                    return True

        # Pattern search: find functions with 3+ TST+B.EQ+MOVK(#0xc8a2)
        # triplets and 0 BL callers. This is the chained fixup rebase code.
        ks, ke = self.kern_text
        off = ks
        while off < ke - 4:
            d = self._disas_at(off)
            if not d or d[0].mnemonic != "pacibsp":
                off += 4
                continue
            func_start = off
            func_end = self._find_func_end(func_start, 0x2000)

            # Must have 0 BL callers (indirect call via function pointer)
            if self.bl_callers.get(func_start, []):
                off = func_end
                continue

            # Count TST+B.EQ+MOVK(#0xc8a2) triplets
            triplets = []
            for o in range(func_start, func_end - 8, 4):
                d3 = self._disas_at(o, 3)
                if len(d3) < 3:
                    continue
                i0, i1, i2 = d3[0], d3[1], d3[2]
                if (
                    i0.mnemonic == "tst"
                    and "40000000000000" in i0.op_str
                    and i1.mnemonic == "b.eq"
                    and i2.mnemonic == "movk"
                    and "#0xc8a2" in i2.op_str
                ):
                    beq_target = i1.operands[-1].imm
                    triplets.append((o, beq_target))

            if len(triplets) >= 3:
                # Patch the last triplet (deepest in the function)
                tst_off, beq_target = triplets[-1]
                b_bytes = self._encode_b(tst_off, beq_target)
                if b_bytes:
                    self._log(
                        f"  [+] rebase func at 0x{func_start:X}, "
                        f"patch TST at 0x{tst_off:X}"
                    )
                    self.emit(
                        tst_off,
                        b_bytes,
                        f"b #0x{beq_target - tst_off:X} [_load_dylinker PAC bypass]",
                    )
                    return True

            off = func_end

        self._log("  [-] PAC rebase function not found")
        return False

    def _find_tst_pac_triplet(self, start, end):
        """Find last TST+B.EQ+MOVK(#0xc8a2) triplet. Returns (tst_off, beq_target)."""
        last = None
        for off in range(start, end - 8, 4):
            d = self._disas_at(off, 3)
            if len(d) < 3:
                continue
            i0, i1, i2 = d[0], d[1], d[2]
            if (
                i0.mnemonic == "tst"
                and "40000000000000" in i0.op_str
                and i1.mnemonic == "b.eq"
                and i2.mnemonic == "movk"
                and "#0xc8a2" in i2.op_str
            ):
                last = (off, i1.operands[-1].imm)
        return last

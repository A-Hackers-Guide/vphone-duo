"""Mixin: KernelJBPatchMacMountMixin."""

from .kernel_jb_base import NOP, MOV_X8_XZR


class KernelJBPatchMacMountMixin:
    def patch_mac_mount(self):
        """Bypass MAC mount check: NOP + mov x8,xzr in ___mac_mount.
        Anchor: 'mount_common()' string → find nearby ___mac_mount function.
        """
        self._log("\n[JB] ___mac_mount: NOP + mov x8,xzr")

        # Try symbol first
        foff = self._resolve_symbol("___mac_mount")
        if foff < 0:
            foff = self._resolve_symbol("__mac_mount")
        if foff < 0:
            # Find via 'mount_common()' string → function area
            # ___mac_mount is typically called from mount_common/kernel_mount
            # Search for a function containing a BL+CBNZ w0 pattern
            # near the mount_common string reference area
            str_off = self.find_string(b"mount_common()")
            if str_off >= 0:
                refs = self.find_string_refs(str_off, *self.kern_text)
                if refs:
                    mount_common_func = self.find_function_start(refs[0][0])
                    if mount_common_func >= 0:
                        # __mac_mount is called from mount_common
                        # Find BL targets from mount_common
                        mc_end = self._find_func_end(mount_common_func, 0x2000)
                        for off in range(mount_common_func, mc_end, 4):
                            target = self._is_bl(off)
                            if (
                                target >= 0
                                and self.kern_text[0] <= target < self.kern_text[1]
                            ):
                                # Check if this target contains BL+CBNZ w0 pattern
                                # (mac check) followed by a mov to x8
                                te = self._find_func_end(target, 0x1000)
                                for off2 in range(target, te - 8, 4):
                                    d0 = self._disas_at(off2)
                                    if not d0 or d0[0].mnemonic != "bl":
                                        continue
                                    d1 = self._disas_at(off2 + 4)
                                    if (
                                        d1
                                        and d1[0].mnemonic == "cbnz"
                                        and d1[0].op_str.startswith("w0,")
                                    ):
                                        foff = target
                                        break
                                if foff >= 0:
                                    break

        if foff < 0:
            self._log("  [-] function not found")
            return False

        func_end = self._find_func_end(foff, 0x1000)
        patched = 0

        for off in range(foff, func_end - 8, 4):
            d0 = self._disas_at(off)
            if not d0 or d0[0].mnemonic != "bl":
                continue
            d1 = self._disas_at(off + 4)
            if not d1:
                continue
            if d1[0].mnemonic == "cbnz" and d1[0].op_str.startswith("w0,"):
                self.emit(off, NOP, "NOP [___mac_mount BL check]")
                patched += 1
                for off2 in range(off + 8, min(off + 0x60, func_end), 4):
                    d2 = self._disas_at(off2)
                    if not d2:
                        continue
                    if d2[0].mnemonic == "mov" and "x8" in d2[0].op_str:
                        if d2[0].op_str != "x8, xzr":
                            self.emit(off2, MOV_X8_XZR, "mov x8,xzr [___mac_mount]")
                            patched += 1
                            break
                break

        if patched == 0:
            self._log("  [-] patch sites not found")
            return False
        return True

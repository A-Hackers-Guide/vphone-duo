"""Mixin: KernelJBPatchCredLabelMixin."""

from .kernel_jb_base import asm, _rd32, RET


class KernelJBPatchCredLabelMixin:
    def patch_cred_label_update_execve(self):
        """Redirect _cred_label_update_execve to shellcode that sets cs_flags.

        Shellcode: LDR x0,[sp,#8]; LDR w1,[x0]; ORR w1,w1,#0x4000000;
                   ORR w1,w1,#0xF; AND w1,w1,#0xFFFFC0FF; STR w1,[x0];
                   MOV x0,xzr; RETAB
        """
        self._log("\n[JB] _cred_label_update_execve: shellcode (cs_flags)")

        # Find the function via AMFI string reference
        func_off = -1

        # Try symbol
        for sym, off in self.symbols.items():
            if "cred_label_update_execve" in sym and "hook" not in sym:
                func_off = off
                break

        if func_off < 0:
            # String anchor: the function is near execve-related AMFI code.
            # Look for the function that contains the AMFI string ref and
            # then find _cred_label_update_execve through BL targets.
            str_off = self.find_string(b"AMFI: code signature validation failed")
            if str_off >= 0:
                refs = self.find_string_refs(str_off, *self.amfi_text)
                if refs:
                    caller = self.find_function_start(refs[0][0])
                    if caller >= 0:
                        # Walk through the AMFI text section to find functions
                        # that have a RETAB at the end and take many arguments
                        # The _cred_label_update_execve has many args and a
                        # distinctive prologue.
                        pass

        if func_off < 0:
            # Alternative: search AMFI text for functions that match the pattern
            # of _cred_label_update_execve (long prologue, many saved regs, RETAB)
            # Look for the specific pattern: mov xN, x2 in early prologue
            # (saves the vnode arg) followed by stp xzr,xzr pattern
            s, e = self.amfi_text
            # Search for PACIBSP functions in AMFI that are BL targets from
            # the execve kill path area
            str_off = self.find_string(b"AMFI: hook..execve() killing")
            if str_off < 0:
                str_off = self.find_string(b"execve() killing")
            if str_off >= 0:
                refs = self.find_string_refs(str_off, s, e)
                if not refs:
                    refs = self.find_string_refs(str_off)
                if refs:
                    kill_func = self.find_function_start(refs[0][0])
                    if kill_func >= 0:
                        kill_end = self._find_func_end(kill_func, 0x800)
                        # The kill function ends with RETAB. The next function
                        # after it should be close to _cred_label_update_execve.
                        # Actually, _cred_label_update_execve is typically the
                        # function BEFORE the kill function.
                        # Search backward from kill_func for a RETAB/RET
                        for back in range(kill_func - 4, max(kill_func - 0x400, s), -4):
                            val = _rd32(self.raw, back)
                            if val in (0xD65F0FFF, 0xD65F0BFF, 0xD65F03C0):
                                # Found end of previous function.
                                # The function we want starts at the next PACIBSP before back.
                                for scan in range(back - 4, max(back - 0x400, s), -4):
                                    d = self._disas_at(scan)
                                    if d and d[0].mnemonic == "pacibsp":
                                        func_off = scan
                                        break
                                break

        if func_off < 0:
            self._log("  [-] function not found, skipping shellcode patch")
            return False

        # Find code cave
        cave = self._find_code_cave(32)  # 8 instructions = 32 bytes
        if cave < 0:
            self._log("  [-] no code cave found for shellcode")
            return False

        # Assemble shellcode
        shellcode = (
            asm("ldr x0, [sp, #8]")  # load cred pointer
            + asm("ldr w1, [x0]")  # load cs_flags
            + asm("orr w1, w1, #0x4000000")  # set CS_PLATFORM_BINARY
            + asm(
                "orr w1, w1, #0xF"
            )  # set CS_VALID|CS_ADHOC|CS_GET_TASK_ALLOW|CS_INSTALLER
            + bytes(
                [0x21, 0x64, 0x12, 0x12]
            )  # AND w1, w1, #0xFFFFC0FF (clear CS_HARD|CS_KILL etc)
            + asm("str w1, [x0]")  # store back
            + asm("mov x0, xzr")  # return 0
            + bytes([0xFF, 0x0F, 0x5F, 0xD6])  # RETAB
        )

        # Find the return site in the function (last RETAB)
        func_end = self._find_func_end(func_off, 0x200)
        ret_off = -1
        for off in range(func_end - 4, func_off, -4):
            val = _rd32(self.raw, off)
            if val in (0xD65F0FFF, 0xD65F0BFF, 0xD65F03C0):
                ret_off = off
                break
        if ret_off < 0:
            self._log("  [-] function return not found")
            return False

        # Write shellcode to cave
        for i in range(0, len(shellcode), 4):
            self.emit(
                cave + i,
                shellcode[i : i + 4],
                f"shellcode+{i} [_cred_label_update_execve]",
            )

        # Branch from function return to cave
        b_bytes = self._encode_b(ret_off, cave)
        if b_bytes:
            self.emit(
                ret_off, b_bytes, f"b cave [_cred_label_update_execve -> 0x{cave:X}]"
            )
        else:
            self._log("  [-] branch to cave out of range")
            return False

        return True

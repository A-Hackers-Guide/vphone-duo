"""Mixin: KernelJBPatchSyscallmaskMixin."""

from .kernel_jb_base import asm, _rd32, _rd64, RET, struct


class KernelJBPatchSyscallmaskMixin:
    def patch_syscallmask_apply_to_proc(self):
        """Redirect _syscallmask_apply_to_proc to custom filter shellcode.
        Anchor: 'syscallmask.c' string → find function → redirect to cave.
        """
        self._log("\n[JB] _syscallmask_apply_to_proc: shellcode (filter mask)")

        # Resolve required functions
        func_off = self._resolve_symbol("_syscallmask_apply_to_proc")
        zalloc_off = self._resolve_symbol("_zalloc_ro_mut")
        filter_off = self._resolve_symbol("_proc_set_syscall_filter_mask")

        if func_off < 0:
            # String anchor: "syscallmask.c"
            str_off = self.find_string(b"syscallmask.c")
            if str_off >= 0:
                refs = self.find_string_refs(str_off, *self.kern_text)
                if not refs:
                    refs = self.find_string_refs(str_off)
                if refs:
                    # The function containing this string ref is in the
                    # syscallmask module. Find _syscallmask_apply_to_proc
                    # by looking for a function nearby that takes 4 args.
                    base_func = self.find_function_start(refs[0][0])
                    if base_func >= 0:
                        # Search nearby functions for the one that has a
                        # BL to _proc_set_syscall_filter_mask-like function.
                        # Actually, the function with "syscallmask.c" IS likely
                        # _syscallmask_apply_to_proc or very close to it.
                        func_off = base_func

        if func_off < 0:
            self._log("  [-] _syscallmask_apply_to_proc not found")
            return False

        # Find _zalloc_ro_mut: search for the BL target from within the function
        # that's called with specific arguments. Use BL callers analysis.
        if zalloc_off < 0:
            func_end = self._find_func_end(func_off, 0x200)
            for off in range(func_off, func_end, 4):
                target = self._is_bl(off)
                if target >= 0:
                    # _zalloc_ro_mut is typically one of the BL targets
                    # It's the one with many callers (>50)
                    # bl_callers is keyed by file offset (same as _is_bl returns)
                    n = len(self.bl_callers.get(target, []))
                    if n > 50:
                        zalloc_off = target
                        break

        # Find _proc_set_syscall_filter_mask: search for a BL or B target
        if filter_off < 0:
            func_end = self._find_func_end(func_off, 0x200)
            # It's typically the last BL/B target in the function (tail call)
            for off in range(func_end - 4, func_off, -4):
                target = self._is_bl(off)
                if target >= 0:
                    filter_off = target
                    break
                # Also check for unconditional B
                val = _rd32(self.raw, off)
                if (val & 0xFC000000) == 0x14000000:
                    imm26 = val & 0x3FFFFFF
                    if imm26 & (1 << 25):
                        imm26 -= 1 << 26
                    target = off + imm26 * 4
                    if self.kern_text[0] <= target < self.kern_text[1]:
                        filter_off = target
                        break

        if zalloc_off < 0 or filter_off < 0:
            self._log(
                f"  [-] required functions not found "
                f"(zalloc={'found' if zalloc_off >= 0 else 'missing'}, "
                f"filter={'found' if filter_off >= 0 else 'missing'})"
            )
            return False

        # Find code cave (need ~160 bytes)
        cave = self._find_code_cave(160)
        if cave < 0:
            self._log("  [-] no code cave found")
            return False

        cave_base = cave

        # Encode BL to _zalloc_ro_mut (at cave + 28*4)
        zalloc_bl_off = cave_base + 28 * 4
        zalloc_bl = self._encode_bl(zalloc_bl_off, zalloc_off)
        if not zalloc_bl:
            self._log("  [-] BL to _zalloc_ro_mut out of range")
            return False

        # Encode B to _proc_set_syscall_filter_mask (at end of shellcode)
        filter_b_off = cave_base + 37 * 4
        filter_b = self._encode_b(filter_b_off, filter_off)
        if not filter_b:
            self._log("  [-] B to _proc_set_syscall_filter_mask out of range")
            return False

        # Build shellcode
        shellcode_parts = []
        for _ in range(10):
            shellcode_parts.append(b"\xff\xff\xff\xff")

        shellcode_parts.append(asm("cbz x2, #0x6c"))  # idx 10
        shellcode_parts.append(asm("sub sp, sp, #0x40"))  # idx 11
        shellcode_parts.append(asm("stp x19, x20, [sp, #0x10]"))  # idx 12
        shellcode_parts.append(asm("stp x21, x22, [sp, #0x20]"))  # idx 13
        shellcode_parts.append(asm("stp x29, x30, [sp, #0x30]"))  # idx 14
        shellcode_parts.append(asm("mov x19, x0"))  # idx 15
        shellcode_parts.append(asm("mov x20, x1"))  # idx 16
        shellcode_parts.append(asm("mov x21, x2"))  # idx 17
        shellcode_parts.append(asm("mov x22, x3"))  # idx 18
        shellcode_parts.append(asm("mov x8, #8"))  # idx 19
        shellcode_parts.append(asm("mov x0, x17"))  # idx 20
        shellcode_parts.append(asm("mov x1, x21"))  # idx 21
        shellcode_parts.append(asm("mov x2, #0"))  # idx 22
        # adr x3, #-0x5C — encode manually
        adr_delta = -(23 * 4)
        immhi = (adr_delta >> 2) & 0x7FFFF
        immlo = adr_delta & 0x3
        adr_insn = 0x10000003 | (immlo << 29) | (immhi << 5)
        shellcode_parts.append(struct.pack("<I", adr_insn))  # idx 23
        shellcode_parts.append(asm("udiv x4, x22, x8"))  # idx 24
        shellcode_parts.append(asm("msub x10, x4, x8, x22"))  # idx 25
        shellcode_parts.append(asm("cbz x10, #8"))  # idx 26
        shellcode_parts.append(asm("add x4, x4, #1"))  # idx 27
        shellcode_parts.append(zalloc_bl)  # idx 28
        shellcode_parts.append(asm("mov x0, x19"))  # idx 29
        shellcode_parts.append(asm("mov x1, x20"))  # idx 30
        shellcode_parts.append(asm("mov x2, x21"))  # idx 31
        shellcode_parts.append(asm("mov x3, x22"))  # idx 32
        shellcode_parts.append(asm("ldp x19, x20, [sp, #0x10]"))  # idx 33
        shellcode_parts.append(asm("ldp x21, x22, [sp, #0x20]"))  # idx 34
        shellcode_parts.append(asm("ldp x29, x30, [sp, #0x30]"))  # idx 35
        shellcode_parts.append(asm("add sp, sp, #0x40"))  # idx 36
        shellcode_parts.append(filter_b)  # idx 37

        # Write shellcode
        for i, part in enumerate(shellcode_parts):
            self.emit(
                cave_base + i * 4,
                part,
                f"shellcode+{i * 4} [_syscallmask_apply_to_proc]",
            )

        # Redirect original function
        func_end = self._find_func_end(func_off, 0x200)
        for off in range(func_off, min(func_off + 0x100, func_end), 4):
            d = self._disas_at(off)
            if not d:
                continue
            if d[0].mnemonic == "bl":
                self.emit(
                    off - 4,
                    asm("mov x17, x0"),
                    "mov x17,x0 [_syscallmask_apply_to_proc inject]",
                )
                b_to_cave = self._encode_b(off, cave_base + 10 * 4)
                if b_to_cave:
                    self.emit(
                        off,
                        b_to_cave,
                        f"b cave [_syscallmask_apply_to_proc -> 0x{cave_base + 40:X}]",
                    )
                return True

        self._log("  [-] injection point not found")
        return False

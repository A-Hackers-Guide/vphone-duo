"""Mixin: KernelJBPatchKcall10Mixin."""

from .kernel_jb_base import asm, _rd32, _rd64, RET, NOP, struct


class KernelJBPatchKcall10Mixin:
    def patch_kcall10(self):
        """Replace SYS_kas_info (syscall 439) with kcall10 shellcode.

        Anchor: find _nosys function by pattern, then search DATA segments
        for the sysent table (first entry points to _nosys).
        """
        self._log("\n[JB] kcall10: syscall 439 replacement")

        # Find _nosys
        nosys_off = self._resolve_symbol("_nosys")
        if nosys_off < 0:
            nosys_off = self._find_nosys()
        if nosys_off < 0:
            self._log("  [-] _nosys not found")
            return False

        self._log(f"  [+] _nosys at 0x{nosys_off:X}")

        # Find _munge_wwwwwwww
        munge_off = self._resolve_symbol("_munge_wwwwwwww")
        if munge_off < 0:
            for sym, off in self.symbols.items():
                if "munge_wwwwwwww" in sym:
                    munge_off = off
                    break

        # Search for sysent table in DATA segments
        sysent_off = -1
        for seg_name, vmaddr, fileoff, filesize, _ in self.all_segments:
            if "DATA" not in seg_name:
                continue
            for off in range(fileoff, fileoff + filesize - 24, 8):
                val = _rd64(self.raw, off)
                decoded = self._decode_chained_ptr(val)
                if decoded == nosys_off:
                    # Verify: sysent[1] should also point to valid code
                    val2 = _rd64(self.raw, off + 24)
                    decoded2 = self._decode_chained_ptr(val2)
                    if decoded2 > 0 and any(
                        s <= decoded2 < e for s, e in self.code_ranges
                    ):
                        sysent_off = off
                        break
            if sysent_off >= 0:
                break

        if sysent_off < 0:
            self._log("  [-] sysent table not found")
            return False

        self._log(f"  [+] sysent table at file offset 0x{sysent_off:X}")

        # Entry 439 (SYS_kas_info)
        entry_439 = sysent_off + 439 * 24

        # Find code cave for kcall10 shellcode (~128 bytes = 32 instructions)
        cave = self._find_code_cave(128)
        if cave < 0:
            self._log("  [-] no code cave found")
            return False

        # Build kcall10 shellcode
        parts = [
            asm("ldr x10, [sp, #0x40]"),  # 0
            asm("ldp x0, x1, [x10, #0]"),  # 1
            asm("ldp x2, x3, [x10, #0x10]"),  # 2
            asm("ldp x4, x5, [x10, #0x20]"),  # 3
            asm("ldp x6, x7, [x10, #0x30]"),  # 4
            asm("ldp x8, x9, [x10, #0x40]"),  # 5
            asm("ldr x10, [x10, #0x50]"),  # 6
            asm("mov x16, x0"),  # 7
            asm("mov x0, x1"),  # 8
            asm("mov x1, x2"),  # 9
            asm("mov x2, x3"),  # 10
            asm("mov x3, x4"),  # 11
            asm("mov x4, x5"),  # 12
            asm("mov x5, x6"),  # 13
            asm("mov x6, x7"),  # 14
            asm("mov x7, x8"),  # 15
            asm("mov x8, x9"),  # 16
            asm("mov x9, x10"),  # 17
            asm("stp x29, x30, [sp, #-0x10]!"),  # 18
            bytes([0x00, 0x02, 0x3F, 0xD6]),  # 19: BLR x16
            asm("ldp x29, x30, [sp], #0x10"),  # 20
            asm("ldr x11, [sp, #0x40]"),  # 21
            NOP,  # 22
            asm("stp x0, x1, [x11, #0]"),  # 23
            asm("stp x2, x3, [x11, #0x10]"),  # 24
            asm("stp x4, x5, [x11, #0x20]"),  # 25
            asm("stp x6, x7, [x11, #0x30]"),  # 26
            asm("stp x8, x9, [x11, #0x40]"),  # 27
            asm("str x10, [x11, #0x50]"),  # 28
            asm("mov x0, #0"),  # 29
            asm("ret"),  # 30
            NOP,  # 31
        ]

        for i, part in enumerate(parts):
            self.emit(cave + i * 4, part, f"shellcode+{i * 4} [kcall10]")

        # Patch sysent[439]
        cave_va = self.base_va + cave
        self.emit(
            entry_439,
            struct.pack("<Q", cave_va),
            f"sysent[439].sy_call = 0x{cave_va:X} [kcall10]",
        )

        if munge_off >= 0:
            munge_va = self.base_va + munge_off
            self.emit(
                entry_439 + 8,
                struct.pack("<Q", munge_va),
                f"sysent[439].sy_munge32 = 0x{munge_va:X} [kcall10]",
            )

        # sy_return_type = SYSCALL_RET_UINT64_T (7)
        self.emit(
            entry_439 + 16,
            struct.pack("<I", 7),
            "sysent[439].sy_return_type = 7 [kcall10]",
        )

        # sy_narg = 8, sy_arg_bytes = 0x20
        self.emit(
            entry_439 + 20,
            struct.pack("<I", 0x200008),
            "sysent[439].sy_narg=8,sy_arg_bytes=0x20 [kcall10]",
        )

        return True

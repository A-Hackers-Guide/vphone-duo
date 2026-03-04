"""Mixin: KernelJBPatchHookCredLabelMixin."""

from .kernel_jb_base import asm, _rd32, _rd64, RET, NOP, struct


class KernelJBPatchHookCredLabelMixin:
    def patch_hook_cred_label_update_execve(self):
        """Redirect _hook_cred_label_update_execve ops table entry to shellcode.

        Patches the sandbox MAC ops table entry for cred_label_update_execve
        to point to custom shellcode that performs vnode_getattr ownership
        propagation.  Instead of calling vfs_context_current (which may not
        exist as a BL-callable function), we construct a vfs_context on the
        stack using current_thread (mrs tpidr_el1) and the caller's
        credential (x0 = old_cred).
        """
        self._log("\n[JB] _hook_cred_label_update_execve: ops table + shellcode")

        # ── 1. Find vnode_getattr via string anchor ──────────────
        vnode_getattr_off = self._resolve_symbol("_vnode_getattr")
        if vnode_getattr_off < 0:
            str_off = self.find_string(b"vnode_getattr")
            if str_off >= 0:
                refs = self.find_string_refs(str_off)
                if refs:
                    vnode_getattr_off = self.find_function_start(refs[0][0])
                    if vnode_getattr_off >= 0:
                        self._log(
                            f"  [+] vnode_getattr at 0x"
                            f"{vnode_getattr_off:X} (via string)"
                        )

        if vnode_getattr_off < 0:
            self._log("  [-] vnode_getattr not found")
            return False

        # ── 2. Find sandbox ops table ────────────────────────────
        ops_table = self._find_sandbox_ops_table_via_conf()
        if ops_table is None:
            self._log("  [-] sandbox ops table not found")
            return False

        # ── 3. Find hook index dynamically ───────────────────────
        # mpo_cred_label_update_execve is one of the largest sandbox
        # hooks at an early index (< 30).  Scan for it.
        hook_index = -1
        orig_hook = -1
        best_size = 0
        for idx in range(0, 30):
            entry = self._read_ops_entry(ops_table, idx)
            if entry is None or entry <= 0:
                continue
            if not any(s <= entry < e for s, e in self.code_ranges):
                continue
            fend = self._find_func_end(entry, 0x2000)
            fsize = fend - entry
            if fsize > best_size:
                best_size = fsize
                hook_index = idx
                orig_hook = entry

        if hook_index < 0 or best_size < 1000:
            self._log(
                "  [-] hook entry not found in ops table "
                f"(best: idx={hook_index}, size={best_size})"
            )
            return False

        self._log(
            f"  [+] hook at ops[{hook_index}] = 0x{orig_hook:X} ({best_size} bytes)"
        )

        # ── 4. Find code cave ────────────────────────────────────
        cave = self._find_code_cave(180)
        if cave < 0:
            self._log("  [-] no code cave found")
            return False
        self._log(f"  [+] code cave at 0x{cave:X}")

        # ── 5. Encode BL to vnode_getattr ────────────────────────
        vnode_bl_off = cave + 17 * 4
        vnode_bl = self._encode_bl(vnode_bl_off, vnode_getattr_off)
        if not vnode_bl:
            self._log("  [-] BL to vnode_getattr out of range")
            return False

        # ── 6. Encode B to original hook ─────────────────────────
        b_back_off = cave + 44 * 4
        b_back = self._encode_b(b_back_off, orig_hook)
        if not b_back:
            self._log("  [-] B to original hook out of range")
            return False

        # ── 7. Build shellcode ───────────────────────────────────
        # MAC hook args: x0=old_cred, x1=new_cred, x2=proc, x3=vp
        #
        # Parts [8-10] construct a vfs_context on the stack instead
        # of calling vfs_context_current, which may not exist as a
        # direct BL target in stripped ARM64e kernels.
        #
        # struct vfs_context { thread_t vc_thread; kauth_cred_t vc_ucred; }
        # We place it at [sp, #0x70] (between saved regs and vattr buffer).
        parts = []
        parts.append(NOP)  # 0
        parts.append(asm("cbz x3, #0xa8"))  # 1
        parts.append(asm("sub sp, sp, #0x400"))  # 2
        parts.append(asm("stp x29, x30, [sp]"))  # 3
        parts.append(asm("stp x0, x1, [sp, #16]"))  # 4
        parts.append(asm("stp x2, x3, [sp, #32]"))  # 5
        parts.append(asm("stp x4, x5, [sp, #48]"))  # 6
        parts.append(asm("stp x6, x7, [sp, #64]"))  # 7
        # Construct vfs_context inline (replaces BL vfs_context_current)
        parts.append(asm("mrs x8, tpidr_el1"))  # 8: current_thread
        parts.append(asm("stp x8, x0, [sp, #0x70]"))  # 9: {thread, cred}
        parts.append(asm("add x2, sp, #0x70"))  # 10: ctx = &vfs_ctx
        # Setup vnode_getattr(vp, &vattr, ctx)
        parts.append(asm("ldr x0, [sp, #0x28]"))  # 11: x0 = vp
        parts.append(asm("add x1, sp, #0x80"))  # 12: x1 = &vattr
        parts.append(asm("mov w8, #0x380"))  # 13: vattr size
        parts.append(asm("stp xzr, x8, [x1]"))  # 14: init vattr
        parts.append(asm("stp xzr, xzr, [x1, #0x10]"))  # 15: init vattr
        parts.append(NOP)  # 16
        parts.append(vnode_bl)  # 17: BL vnode_getattr
        # Check result + propagate ownership
        parts.append(asm("cbnz x0, #0x50"))  # 18: error → skip
        parts.append(asm("mov w2, #0"))  # 19: changed = 0
        parts.append(asm("ldr w8, [sp, #0xCC]"))  # 20: va_mode
        parts.append(bytes([0xA8, 0x00, 0x58, 0x36]))  # 21: tbz w8,#11
        parts.append(asm("ldr w8, [sp, #0xC4]"))  # 22: va_uid
        parts.append(asm("ldr x0, [sp, #0x18]"))  # 23: new_cred
        parts.append(asm("str w8, [x0, #0x18]"))  # 24: cred->uid
        parts.append(asm("mov w2, #1"))  # 25: changed = 1
        parts.append(asm("ldr w8, [sp, #0xCC]"))  # 26: va_mode
        parts.append(bytes([0xA8, 0x00, 0x50, 0x36]))  # 27: tbz w8,#10
        parts.append(asm("mov w2, #1"))  # 28: changed = 1
        parts.append(asm("ldr w8, [sp, #0xC8]"))  # 29: va_gid
        parts.append(asm("ldr x0, [sp, #0x18]"))  # 30: new_cred
        parts.append(asm("str w8, [x0, #0x28]"))  # 31: cred->gid
        parts.append(asm("cbz w2, #0x1c"))  # 32: if !changed
        parts.append(asm("ldr x0, [sp, #0x20]"))  # 33: proc
        parts.append(asm("ldr w8, [x0, #0x454]"))  # 34: p_csflags
        parts.append(asm("orr w8, w8, #0x100"))  # 35: CS_VALID
        parts.append(asm("str w8, [x0, #0x454]"))  # 36: store
        parts.append(asm("ldp x0, x1, [sp, #16]"))  # 37: restore
        parts.append(asm("ldp x2, x3, [sp, #32]"))  # 38
        parts.append(asm("ldp x4, x5, [sp, #48]"))  # 39
        parts.append(asm("ldp x6, x7, [sp, #64]"))  # 40
        parts.append(asm("ldp x29, x30, [sp]"))  # 41
        parts.append(asm("add sp, sp, #0x400"))  # 42
        parts.append(NOP)  # 43
        parts.append(b_back)  # 44: B orig_hook

        for i, part in enumerate(parts):
            self.emit(
                cave + i * 4,
                part,
                f"shellcode+{i * 4} [_hook_cred_label_update_execve]",
            )

        # ── 8. Rewrite ops table entry ───────────────────────────
        # Preserve auth rebase upper 32 bits (PAC key, diversity,
        # chain next) and replace lower 32 bits with cave foff.
        entry_off = ops_table + hook_index * 8
        orig_raw = _rd64(self.raw, entry_off)
        new_raw = (orig_raw & 0xFFFFFFFF00000000) | (cave & 0xFFFFFFFF)
        self.emit(
            entry_off,
            struct.pack("<Q", new_raw),
            f"ops_table[{hook_index}] = cave 0x{cave:X} "
            f"[_hook_cred_label_update_execve]",
        )

        return True

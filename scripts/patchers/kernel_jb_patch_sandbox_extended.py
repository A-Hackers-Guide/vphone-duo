"""Mixin: KernelJBPatchSandboxExtendedMixin."""

from .kernel_jb_base import MOV_X0_0, RET


class KernelJBPatchSandboxExtendedMixin:
    def patch_sandbox_hooks_extended(self):
        """Stub remaining sandbox MACF hooks (JB extension beyond base 5 hooks)."""
        self._log("\n[JB] Sandbox extended hooks: mov x0,#0; ret")

        ops_table = self._find_sandbox_ops_table_via_conf()
        if ops_table is None:
            return False

        HOOK_INDICES_EXT = {
            "vnode_check_getattr": 245,
            "proc_check_get_cs_info": 249,
            "proc_check_set_cs_info": 250,
            "proc_check_set_cs_info2": 252,
            "vnode_check_chroot": 254,
            "vnode_check_create": 255,
            "vnode_check_deleteextattr": 256,
            "vnode_check_exchangedata": 257,
            "vnode_check_exec": 258,
            "vnode_check_getattrlist": 259,
            "vnode_check_getextattr": 260,
            "vnode_check_ioctl": 261,
            "vnode_check_link": 264,
            "vnode_check_listextattr": 265,
            "vnode_check_open": 267,
            "vnode_check_readlink": 270,
            "vnode_check_setattrlist": 275,
            "vnode_check_setextattr": 276,
            "vnode_check_setflags": 277,
            "vnode_check_setmode": 278,
            "vnode_check_setowner": 279,
            "vnode_check_setutimes": 280,
            "vnode_check_stat": 281,
            "vnode_check_truncate": 282,
            "vnode_check_unlink": 283,
            "vnode_check_fsgetpath": 316,
        }

        sb_start, sb_end = self.sandbox_text
        patched = 0
        seen = set()

        for hook_name, idx in HOOK_INDICES_EXT.items():
            func_off = self._read_ops_entry(ops_table, idx)
            if func_off is None or func_off <= 0:
                continue
            if not (sb_start <= func_off < sb_end):
                continue
            if func_off in seen:
                continue
            seen.add(func_off)

            self.emit(func_off, MOV_X0_0, f"mov x0,#0 [_hook_{hook_name}]")
            self.emit(func_off + 4, RET, f"ret [_hook_{hook_name}]")
            patched += 1

        if patched == 0:
            self._log("  [-] no extended sandbox hooks patched")
            return False
        return True

    # ══════════════════════════════════════════════════════════════
    # Group B: Simple patches
    # ══════════════════════════════════════════════════════════════

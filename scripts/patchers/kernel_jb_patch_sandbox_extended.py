"""Mixin: KernelJBPatchSandboxExtendedMixin."""

from .kernel_jb_base import MOV_X0_0, RET, struct, _rd64


class KernelJBPatchSandboxExtendedMixin:
    def patch_sandbox_hooks_extended(self):
        """Retarget extended Sandbox MACF hooks to the common allow stub.

        Upstream `patch_fw.py` rewrites the `mac_policy_ops` entries rather than
        patching each hook body. Keep the same runtime strategy here:
        recover
        `mac_policy_ops` from `mac_policy_conf`, recover the shared
        `mov x0,#0; ret` Sandbox stub, then retarget the selected ops entries
        while preserving their chained-fixup/PAC metadata.
        """
        self._log("\n[JB] Sandbox extended hooks: retarget ops entries to allow stub")

        ops_table = self._find_sandbox_ops_table_via_conf()
        if ops_table is None:
            return False

        allow_stub = self._find_sandbox_allow_stub()
        if allow_stub is None:
            self._log("  [-] common Sandbox allow stub not found")
            return False

        hook_indices_ext = {
            "iokit_check_201": 201,
            "iokit_check_202": 202,
            "iokit_check_203": 203,
            "iokit_check_204": 204,
            "iokit_check_205": 205,
            "iokit_check_206": 206,
            "iokit_check_207": 207,
            "iokit_check_208": 208,
            "iokit_check_209": 209,
            "iokit_check_210": 210,
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

        patched = 0
        for hook_name, idx in hook_indices_ext.items():
            entry_off = ops_table + idx * 8
            if entry_off + 8 > self.size:
                continue
            entry_raw = _rd64(self.raw, entry_off)
            if entry_raw == 0:
                continue
            entry_new = self._encode_auth_rebase_like(entry_raw, allow_stub)
            if entry_new is None:
                continue
            self.emit(
                entry_off,
                entry_new,
                f"ops[{idx}] -> allow stub [_hook_{hook_name}]",
            )
            patched += 1

        if patched == 0:
            self._log("  [-] no extended sandbox hooks retargeted")
            return False
        return True

    def _find_sandbox_allow_stub(self):
        """Return the common Sandbox `mov x0,#0; ret` stub used by patch_fw.

        On PCC 26.1 research/release there are two such tiny stubs in Sandbox
        text; the higher-address one matches upstream `patch_fw.py`
        (`0x23B73BC` research, `0x22A78BC` release). Keep the reveal
        structural: scan Sandbox text for 2-insn `mov x0,#0; ret` stubs and
        select the highest-address candidate.
        """
        sb_start, sb_end = self.sandbox_text
        hits = []
        for off in range(sb_start, sb_end - 8, 4):
            if self.raw[off:off + 4] == MOV_X0_0 and self.raw[off + 4:off + 8] == RET:
                hits.append(off)
        if len(hits) < 1:
            return None
        allow_stub = max(hits)
        self._log(f"  [+] common Sandbox allow stub at 0x{allow_stub:X}")
        return allow_stub

    @staticmethod
    def _encode_auth_rebase_like(orig_val, target_off):
        """Retarget an auth-rebase chained pointer while preserving PAC bits."""
        if (orig_val & (1 << 63)) == 0:
            return None
        return struct.pack("<Q", (orig_val & ~0xFFFFFFFF) | (target_off & 0xFFFFFFFF))

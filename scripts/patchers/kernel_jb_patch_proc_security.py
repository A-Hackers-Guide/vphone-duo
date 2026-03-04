"""Mixin: KernelJBPatchProcSecurityMixin."""

from .kernel_jb_base import ARM64_OP_IMM, MOV_X0_0, RET, Counter


class KernelJBPatchProcSecurityMixin:
    def patch_proc_security_policy(self):
        """Stub _proc_security_policy: mov x0,#0; ret.

        Anchor: find _proc_info via its distinctive switch-table pattern
        (sub wN,wM,#1; cmp wN,#0x21), then identify the most-called BL
        target within that function — that's _proc_security_policy.
        """
        self._log("\n[JB] _proc_security_policy: mov x0,#0; ret")

        # Try symbol first
        foff = self._resolve_symbol("_proc_security_policy")
        if foff >= 0:
            self.emit(foff, MOV_X0_0, "mov x0,#0 [_proc_security_policy]")
            self.emit(foff + 4, RET, "ret [_proc_security_policy]")
            return True

        # Find _proc_info by its distinctive switch table
        # Pattern: sub wN, wM, #1; cmp wN, #0x21 (33 = max proc_info callnum)
        proc_info_func = -1
        ks, ke = self.kern_text
        for off in range(ks, ke - 8, 4):
            d = self._disas_at(off, 2)
            if len(d) < 2:
                continue
            i0, i1 = d[0], d[1]
            if i0.mnemonic != "sub" or i1.mnemonic != "cmp":
                continue
            # sub wN, wM, #1
            if len(i0.operands) < 3:
                continue
            if i0.operands[2].type != ARM64_OP_IMM or i0.operands[2].imm != 1:
                continue
            # cmp wN, #0x21
            if len(i1.operands) < 2:
                continue
            if i1.operands[1].type != ARM64_OP_IMM or i1.operands[1].imm != 0x21:
                continue
            # Verify same register
            if i0.operands[0].reg != i1.operands[0].reg:
                continue
            # Found it — find function start
            proc_info_func = self.find_function_start(off)
            break

        if proc_info_func < 0:
            self._log("  [-] _proc_info function not found")
            return False

        proc_info_end = self._find_func_end(proc_info_func, 0x4000)
        self._log(
            f"  [+] _proc_info at 0x{proc_info_func:X} (size 0x{proc_info_end - proc_info_func:X})"
        )

        # Count BL targets within _proc_info — the most frequent one
        # is _proc_security_policy (called once per switch case)
        bl_targets = Counter()
        for off in range(proc_info_func, proc_info_end, 4):
            target = self._is_bl(off)
            if target >= 0 and ks <= target < ke:
                bl_targets[target] += 1

        if not bl_targets:
            self._log("  [-] no BL targets found in _proc_info")
            return False

        # The security policy check is called the most (once per case)
        most_called = bl_targets.most_common(1)[0]
        foff = most_called[0]
        count = most_called[1]
        self._log(f"  [+] most-called BL target: 0x{foff:X} ({count} calls)")

        if count < 3:
            self._log("  [-] most-called target has too few calls")
            return False

        self.emit(foff, MOV_X0_0, "mov x0,#0 [_proc_security_policy]")
        self.emit(foff + 4, RET, "ret [_proc_security_policy]")
        return True

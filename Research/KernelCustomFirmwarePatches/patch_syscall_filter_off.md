# `patchSyscallFilterOff` (`kernel-exp-frida_syscall_filter_off`)

## Scope

Opt-in Frida patch in `com.vphone.patchset.kernel.frida`, off in every preset
but `experimental`, gated to cloudOS 26.4+. Port of `syscall-filter-off` from
[mowisec/frida_patches_srd](https://github.com/mowisec/frida_patches_srd)
(Apache-2.0).

## Problem

Sandbox profiles can carry per-process syscall filters (the SBPL operations
`syscall-unix`, `syscall-mach`, `syscall-mig`). Sandbox.kext installs them as
bitmasks that XNU tests inline in the BSD syscall, Mach trap and kobject (MIG)
dispatch paths; only a miss consults the MACF policy, which denies and logs.

Frida's agent runs inside the target, so its own calls are judged against the
target's masks. On the vphone guest with `standard`:

- attaching to `trustd`, `apsd`, `cfprefsd`, `backboardd` or `runningboardd`
  kills the target during injection (`ProcessNotRespondingError`). The guest log
  shows `Autobox: trustd(…) deny(1) syscall-mach 27`, `syscall-mig 153`,
  `syscall-mig 191` and `syscall-unix 362` (`kqueue`), and the crash is an
  `EXC_BREAKPOINT` inside frida-agent;
- in `locationd` the agent survives, but `thread_get_state` on its own threads
  returns `KERN_DENIED` (`syscall-mig 153`/`244`), so `Process.enumerateThreads()`
  is empty and Stalker cannot follow anything; symbolication returns bare
  addresses (`syscall-mig 312`).

`kernel-boot-syscallmask` (already in `standard`) replaces the mask Sandbox.kext
installs through the wrapper it hooks, yet these processes still hit their
filters, so the masks reach them some other way (likely the Protobox/Autobox
application at exec). Not investigated further here.

## Approach — read every mask as "no filter"

1. `task_get_mach_trap_filter_mask` → `mov x0, #0 ; ret`
2. `task_get_mach_kobj_filter_mask` → `mov x0, #0 ; ret`
3. `mac_proc_check_syscall_unix` → `mov w0, #0 ; ret`

NULL is the mask of an unfiltered task, so (1) and (2) send every check down the
path the kernel already takes for unfiltered processes; (3) is the MACF hook for
BSD syscalls, where 0 means allowed. All three open with `pacibsp ; stp …,
[sp, #-n]!`, so returning before the prologue happens before anything is signed
or pushed. The rest of the sandbox (file, mach-lookup, IOKit rules) is untouched.

## Semantic Reveal Procedure

Both filter checks inline `bitstr_test(mask, idx)`:

```text
asr  wT, wIdx, #3
ldrb wT, [xMask, wT, sxtw]
and  wS, wIdx, #7
lsr  wT, wT, wS
tbnz wT, #0, allow
```

1. Rejection-only pre-filter on `asr wD, wN, #3`; decode the window around it.
   Capstone 6 decodes the `asr` and `lsr` aliases with two operands (the shift
   is not an operand), so the shift amount is read from the operand's shift
   field, and registers are compared by number.
2. **kobject check** (ipc_kobject_server): `cmn wIdx, #1 ; b.eq` (KOBJ_IDX_NOT_SET)
   before the bitstr test, the bitmap read from `x0` (the accessor's return), and
   `ldr x, [x, #off] ; cbz x` after it. The accessor is
   the `bl` of the `bl accessor ; cbz x0` pair within four instructions above (on
   26.4 an `adrp x8` sits between them).
3. **trap check** (Mach trap dispatch, `osfmk/arm64/bsd_arm64.c`): `bl accessor ; cbz xMask` directly
   before the bitstr test, with the `ldrb` base being the tested register.
4. **unix check** (unix_syscall): `and w1, wNum, #0xffff ; mov x0, xProc ;
   bl check ; mov xR, x0 ; cbnz w0`. That shape alone is not unique: the iPhone
   kernels of iOS 26.0 and 26.2 carry it a second time, calling another function.
   unix_syscall reaches the real call only from the miss of its inlined
   `bitstr_test(proc_syscall_filter_mask(p), syscode)`, so the site must also be
   the target of `ldrb ; and wS, wNum, #7 ; lsr ; tbz wT, #0, site` within 4 KiB
   before it, on the same syscall-number register `wNum`. This anchor is not in
   the SRD finder.
5. Each of the three must match exactly once and resolve to three distinct
   functions, each opening with `pacibsp ; stp …, [sp, #-n]!`; otherwise fail
   closed. Replacement bytes are the keystone-verified `ARM64.movX0_0`,
   `ARM64.movW0_0` and `ARM64.ret`.

## 26.4 Static Validation

Kernel: `kernelcache.research.vphone600` from cloudOS 26.4 (`c0ecdb4b…`).
`patch-component --component kernel-cfw --target-os 26.5 --frida` emits six
records:

```text
0x01D43090: pacibsp -> mov x0, #0   _task_get_mach_trap_filter_mask
0x01D43094: stp x29, x30, [sp, #-0x10]! -> ret
0x01D43120: pacibsp -> mov x0, #0   _task_get_mach_kobj_filter_mask
0x01D43124: stp x29, x30, [sp, #-0x10]! -> ret
0x024CCAE8: pacibsp -> mov w0, #0   _mac_proc_check_syscall_unix
0x024CCAEC: stp x24, x23, [sp, #-0x40]! -> ret
```

The mowisec finder resolves the same three functions on this kernel.

## Runtime Validation (iOS 26.5 guest, cloudOS 26.4, Frida 17.24.3)

| Kernel | attach trustd/apsd/cfprefsd/backboardd/runningboardd | threads + Stalker in locationd |
|---|---|---|
| `standard` + thread_set_state + vm_map_delete | target dies | 0 threads |
| … + tpro_off + **syscall_filter_off** | all attach | 7–9 threads; main-thread, churn and all-thread Stalker pass |

## Validation Requirements

- Dry run emits exactly six `kernel-exp-frida_syscall_filter_off` records at three
  distinct function entries, each originally `pacibsp ; stp`.
- If any of the three shapes does not match exactly once, the patch fails closed.

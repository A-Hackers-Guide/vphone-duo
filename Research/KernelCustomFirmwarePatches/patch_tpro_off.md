# `patchTproOff` (`kernel-exp-frida_tpro_off`)

## Scope

Opt-in Frida patch in `com.vphone.patchset.kernel.frida`, off in every preset
but `experimental`, gated to cloudOS 26.4+. Port of `tpro-off` from
[mowisec/frida_patches_srd](https://github.com/mowisec/frida_patches_srd)
(Apache-2.0), which derived it on an iOS 27 Security Research Device.

## Problem

dyld keeps its state in TPRO pages and flips them between read-only and
read-write itself. Every libdyld API entry asserts that they are read-only and
otherwise aborts with `TPRO regions should not be writable on entry to dyld`.
Frida's spawn handshake re-enters libdyld while dyld's own TPRO window is still
open, so the spawned process aborts:

- `frida -f com.apple.Preferences` fails with `unexpectedly hit a crash with
  codes [ 0x6000000, 0x0 ] … while initializing suspended process`;
- an app caught by spawn gating crashes once it is resumed.

The crash reports show `abort_report_np` called from libdyld
(`_dyld_for_each_objc_class` / `_dyld_objc_class_count`); the guest's processes
carry `TPRO_CONST` regions, so the vphone guest has TPRO.

## Approach — turn TPRO off in the kernel

`_xprr_tpro_enabled` is a `uint32` in `__DATA_CONST`, statically 1. Every
reference is a read guarding the TPRO path, whose false arm is the path the
kernel already takes for processes without TPRO. Writing 0 makes every process
take it, so dyld's check never sees a writable TPRO region. This is global, not
per-process.

## Semantic Reveal Procedure

The flag is data, so the guard that reads it is matched as code and the address
is resolved from it:

1. Rejection-only pre-filter on `orr wD, wN, #2` (VM_REGION_FLAG_TPRO_ENABLED).
2. Decode the nine-instruction window ending after it, at its VA, and require:
   `adrp xA` / `ldr wA, [xA, #off]` (same register) / `cbz wA, skip` /
   `ldr` / `cmp` / `b.lo skip` (same target as the `cbz`) /
   `ldrh wF, [xN, #f]` / `orr wF, wF, #2` / `strh wF, [xN, #f]` (same register
   and memory operand as the `ldrh`).
3. Exactly one window must match; otherwise fail closed.
4. Flag VA = ADRP page + LDR displacement. It must resolve to a file offset inside
   `__DATA_CONST` and hold 1; otherwise fail closed.
5. Write four zero bytes.

## 26.4 Static Validation

Kernel: `kernelcache.research.vphone600` from cloudOS 26.4
(`c0ecdb4b…`). `patch-component --component kernel-cfw --target-os 26.5 --frida`
emits one record:

```text
guard at foff 0x21B8384 (0xfffffe00091bc384):
  adrp x9, … ; ldr w9, [x9, #0x6d4] ; cbz w9 ; … ; orr w8, w8, #2 ; strh w8, [x19, #0x648]
0x007526D4 (0xfffffe00077566d4): 01 00 00 00 -> 00 00 00 00
```

The mowisec finder (`patch_kernel.py`, build-tag check bypassed) resolves the same
flag address on this kernel.

## Runtime Validation (iOS 26.5 guest, cloudOS 26.4, Frida 17.24.3)

| Kernel | `frida -f com.apple.Preferences` | spawn-gated app after resume |
|---|---|---|
| `standard` + thread_set_state + vm_map_delete | abort in libdyld | crashes |
| … + syscall_filter_off | abort in libdyld | crashes |
| … + syscall_filter_off + **tpro_off** | spawns, agent loads | works |

## Validation Requirements

- Dry run emits exactly one `kernel-exp-frida_tpro_off` record, original bytes
  `01 00 00 00`.
- If the guard window does not match exactly once, or the flag is outside
  `__DATA_CONST` or not 1, the patch fails closed.

# iPhone Duo single-display bring-up

## Kernel CSSC fallback (2026-10-25)

This branch starts from upstream main, without the static CSSC trampoline
experiment. On an independent Banana clone, the installed experimental image
panicked with PID 1 SIGILL at user PC 0x2bd6380e8, ESR 0x02000000. The kernel's
exception codes contained the copied instruction 0xdac1a7fe (PACIBSPPC), matching
/usr/lib/libSystem.B.dylib at image offset 0x10e8. CSSC allocation had aborted
the entire X1 cache operation, leaving PAuth/CPA conversion unapplied; the
installer nevertheless continued. The new route retains upstream PAuth/CPA
conversion and handles CSSC independently in the kernel.

Reveal procedure for `kernelcache.research.vphone600`, UUID
784F88D3-2AF5-3D4A-AB00-365607646E44:

1. Find the unique function referencing `Undefined kernel instruction: pc=%p
   instr=%x`. Identify it as XNU handle_uncategorized by decoded control flow,
   not a recovered symbol (the indexed research symbol JSON is absent).
2. Validate its copyin of four bytes from the saved PC and its EL0/EL1 gate.
   Hook only the user path before undefined-instruction triage. The observed
   handler file offset is 0x1e626ec; the hook is 0x1e62918.
3. Follow the handler's existing signed-state manipulation sequence to recover
   ml_check_signed_state (0x1caa37c), ml_sign_thread_state (0x1caa32c) and its
   interrupt disable/restore helpers. Validate register and saved-state ABI,
   PACGA bodies, and the original stack-canary checked epilogue. These names
   are source correlations; offsets are observations, never runtime constants.
4. Plan the complete fixed-size payload and one entry branch before writing.
   Restrict it to persistent __TEXT_EXEC; do not use boot-only reclaimed text.
   Unknown or ambiguous layouts abort the selected operation.

The fallback accepts only 64-bit user saved states with an uncategorized
exception and successful instruction copyin. It evaluates scalar ABS/CNT/CTZ
and signed/unsigned MIN/MAX register and immediate forms, preserving the
saved NZCV and all unrelated registers. W results zero-extend and register 31
is ZR. A successful operation verifies the old signed state, updates the
destination and PC, and re-signs with the new LR/X16/X17 when applicable.
There are no stack accesses while SPSel selects the interrupt stack. The
original canary check and epilogue remain in use. Unknown words preserve the
original instruction, registers, kernel flags and exception path.

Kernel emulation has per-execution exception overhead. Native CSSC execution
does not enter this fallback; PAuth/CPA retain the existing X1 conversion path.

## Scope and inputs (2026-10-23)

This experiment attempts to boot the iPhone Duo userland on the existing
vphone600 virtual hardware. It registers one outer panel, not two displays or a hinge.
The inner panel, folding poses and physical Duo hardware are not emulated.

- Host: Apple Silicon, macOS 27.0.1 (26A434), without CSSC, CPA or PAuth_LR.
- Guest: `iPhone19,4`, board `v68ap`, iOS 27.1 (24A94425).
- IPSW: <https://updates.cdn-apple.com/2026FallFCS/3f41a447-d8a6-48ae-83ae-056a64f57fd4/iPhone19,4_27.1_24A94425_Restore.ipsw>.
- Size: 12,724,731,538 bytes.
- SHA-256, verified after download:
  `58fbfda85615e90221136d55288f64c9f41386510f8cd77feb8c9d20cc0a782e`.
- CloudOS: 26.4 beta (23E5207q), the existing recommended vphone600 image.
- Preset: `standard`; boot ROMs: the bundle's OpenAVB and OpenSEP.
- VM configuration: 8 CPUs, 8192 MiB RAM, 64 GiB disk, created without a template.
- Core Bundle: a local 2.12.0 build; installed and passed execution policy
  and host preflight.

## Evidence and initial implementation

The restore archive's `BuildManifest.plist` and `Restore.plist` both name
`iPhone19,4`, build 24A94425 and device class `v68ap`. Restore.plist records
CPID 33120 (`0x8160`), BDID 14 (`0x0e`), platform `t8160`.

The archive contains `Firmware/all_flash/DeviceTree.v68ap.im4p`. Its `/product`
records `app-macho-architecture = arm64e.x1`, `artwork-device-idiom = phone`,
`artwork-device-subtype = 2034`, `artwork-scale-factor = 3`, plus `display0`
and `display1` children. The former has display index 0, rotation 0 and scale
3; the latter has index 1, rotation 270 and scale 3. Those are source device
properties, not proof that both panels work in the VM.

The initial model entry uses the outer display's 1398 x 2034 pixels at 460
ppi and 3x, as published in [Apple's technical specifications](https://www.apple.com/iphone-duo/specs/).
The catalog adds only the released 27.1 IPSW, paired with the existing
recommended cloudOS. No new instruction patch or preset is introduced;
the current iOS 27 and ARM64E_X1 patches are exercised on this new userland.

`VPhoneCoreKitTests/GuestDeviceTests` and
`VPhoneCoreKitTests/FirmwareCatalogReportTests` passed: 26 tests total.
The complete `VPhone` Debug build passed. Its finished bundle and a ZIP
round-trip both passed strict, nested, all-architecture signature validation
before the local bundle was installed through Launchpad.

## Boot validation

**Result: does not boot to userspace on this host.** Firmware preparation,
boot-chain patching, DFU restore and CFW installation completed. Template
setup failed while waiting for vphoned because the guest panicked. A subsequent
windowed `vm start <name> --wait --timeout 300` reproduced it before any guest
agent connection or SpringBoard UI:

```text
initproc failed to start -- exit reason namespace 2 subcode 0x4 description: none
Panicked task ... pid 1: launchd
Kernel UUID: 784F88D3-2AF5-3D4A-AB00-365607646E44
```

Namespace 2/subcode 4 reports SIGILL. The saved user-space backtrace LR is not
a recovered fault PC or a verified unslid symbol address. Do not infer an
exact instruction from it without the image load address and fault state.
Runtime addresses and local machine identifiers are omitted from this record.
The VM was stopped after preserving the console log. Its disk,
firmware and installed guest environment remain available for investigation.

### Identified instruction compatibility gap

Host feature queries return zero for `hw.optional.arm.FEAT_CSSC`,
`hw.optional.arm.FEAT_CPA` and `hw.optional.arm.FEAT_PAuth_LR`.
The installed, already X1-lowered `/usr/lib/dyld` still contains scalar CSSC
instructions: for example `UMIN X8,X8,X1` at image offset `0x9570`, `UMAX`
at `0x8ba8`, and `CTZ W10,W21` at `0x1af04`. These are measured offsets in
the 24A94425 dyld, for investigation only, never patch-site constants.

`VPhoneArm64eX1Lowering` and the runtime X1 handler currently lower PAuth_LR
and CPA forms, not these CSSC operations. CSSC therefore is a confirmed
compatibility gap and a candidate explanation for the SIGILL, not yet a
proved fault-site attribution. The cache's early-boot closure and later
runtime code also need auditing before claiming 27.1 support. A safe fix
needs correct register width, operand aliasing, NZCV preservation and immediate
forms; replacing a min/max with an unconditional move is not equivalent.

### Other observed gaps

- Four optional VirtualAudio patches failed together because the old reveal
  expected a `retab` after the throw at `0x171cd0`:
  `system-virtualaudio-cfw-mute_set_throw`,
  `system-virtualaudio-cfw-speaker_protection_gate`,
  `system-virtualaudio-cfw-speaker_route_throws`, and
  `system-virtualaudio-cfw-volume_mode_precondition`.
- The shared-region preflight attempted the ordinary arm64e filename and
  skipped its check; later cache patching correctly found 79 X1 chunks and
  measured `sharedRegionSize = 0x17ce04000`, `maxSlide = 0x20000000`, then
  zeroed maxSlide. No cache-size overflow was reported by that later stage.
- Existing X1 lowering reported 2735 instructions in launchd, with zero
  unvisited candidates. This only counts the instruction forms it recognizes;
  it does not establish support for every instruction in the binary.

The registered model and catalog entry are experimental bring-up inputs,
not a claim of successful Duo support. No CSSC or audio patch was added by
this experiment. Supporting this firmware on hosts without CSSC requires
additional instruction compatibility work; emulating both displays and the
hinge is a separate gap. These results establish limitations of the current
implementation, not that supporting the device is technically impossible.

The original manifests and device tree were extracted by HTTP ranges with
the repository's `VPhoneRemoteZip`. Raw logs and scratch artifacts remain
local; host paths, per-machine identifiers and runtime addresses are not
included in this research record.

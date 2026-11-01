# KextRW host-side integration study

Upstream: <https://github.com/alfiecg24/KextRW> (MIT, © 2025 Alfie CG), derived from
Siguza's [IOKernelRW](https://github.com/Siguza/IOKernelRW). Cloned and reviewed at
`misc/` depth on 2026-10-26. This document is a feasibility study; nothing here is
implemented and no patch set changes are proposed.

## What KextRW actually is

- **Kext** (`src/`, arm64e, built with `clang -mkernel -Wl,-kext` from a plain
  Makefile): an `IOService` on `IOResources` plus a user client with 10 scalar
  selectors — `kread`/`kwrite` (thin `copyout`/`copyin`), `physread`/`physwrite`
  (`IOMemoryDescriptor` physical mapping with alignment modes), `getResetVector`
  (`vbar_el1`), `kvtophys` (an `at s1e1r` sequence in `routines.S`),
  `phystokv` (unimplemented), `callKernelFunction` (a 10-argument variadic
  `arbitrary_call` stub in `routines.S`), `kallocBuffer`/`kfreeBuffer`
  (`com.apple.kpi.unsupported` `kalloc`/`kfree`).
- **Client gate**: the user client checks the *client process entitlement*
  `com.apple.security.alfie.kext-rw` via `copyClientEntitlement` in
  `initWithTask`. Nothing else authenticates the caller.
- **Userland library** (`lib/libkextrw.c`): thin `IOConnectCallScalarMethod`
  wrappers plus `get_kernel_base()` — walk down from `vbar_el1` page-aligned
  until the Mach-O header is found, then compute the slide against a
  hardcoded `STATIC_KERNEL_BASE (0xFFFFFE0007004000)`.
- Tested by upstream only on macOS 15.2 (`OSBundleLibraries` 24.2.0). Loading
  follows the IOKernelRW instructions: kext policy relaxed in Recovery
  (`csrutil enable --without kext` or SIP off) plus user approval.

## Why the guest side is not an integration target

The CFW kernel patch set already ships a default-enabled primitive with the
same power: `patch_kcall10` (JB-05, `sysent[439]` cave, target + 7 args →
`x0`), composed with the task-for-pid / port-to-map / TPRO / vm patches.
Kernel read/write composes from kcall (`copyout`/`copyin`/`kalloc`), so a
guest KextRW adds API shape, not capability. iOS also does not load kexts at
runtime; embedding one into the kernelcache would mean building kext-injection
machinery (kmod info, OSMetaClass registration, `OSBundleLibraries`) that the
patcher philosophy — modify existing code, locate dynamically, no new code
segments — exists to avoid. Rejected.

## Host side: the actual gap

Current admission paths for `vphone-vm`'s restricted entitlements
(`com.apple.private.virtualization.*`, `com.apple.vm.networking`,
`com.apple.private.bmk.allow`):

| | Path A (docs) | Path B (docs) | Path C (this study) |
|---|---|---|---|
| Recovery steps | `csrutil disable` + `allow-research-guests`, plus an extra reboot for `boot-args` | `csrutil enable --without debug` + `allow-research-guests` | enable user management of kexts + `allow-research-guests` |
| Per-build action | none | `vphone-escalator allow` after **every** rebuild (cdhash churn) | none (admission is not cdhash-scoped) |
| Fragility | none (AMFI fully off) | amfid `AMFIRequirementsManager` ivar layout per macOS build — already broke once on M6/`ARM64E.X1` (see `macos27_m6_amfi.md`) | kernel symbol reveal per macOS build |
| Standing security posture | kernel-wide AMFI off, SIP off | SIP on, one amfid heap byte + a code requirement | SIP on, but a resident arbitrary-kernel-RW kext |

So a KextRW fork (call it Path C) targets exactly Path B's two pains: cdhash
churn and amfid-layout fragility. It does not reduce the Recovery burden —
approving a third-party kext on Apple Silicon is *more* interaction than
`csrutil enable --without debug`.

## Path C sketch

1. **Fork hygiene** (the fork is ours to carry):
   - Rename bundle id / IOService / user client class (`com.Alfie.KextRW` →
     e.g. `dev.vphone.kextrw`).
   - **Rename the client entitlement off `com.apple.security.*`.** The
     upstream key lives in Apple's entitlement namespace; if that prefix is
     treated as restricted, an ad hoc client cannot carry it without solving
     the very AMFI problem the kext is meant to replace (circularity). A
     `dev.vphone.*` key keeps `copyClientEntitlement` trivially satisfiable.
   - Trim the selector table to what the admission flow needs (kcall alone
     suffices; kread/kwrite compose from it). Every removed selector removes
     resident-kernel attack surface.
   - Replace `get_kernel_base`'s hardcoded `STATIC_KERNEL_BASE` slide with a
     derivation from the on-disk kernelcache (the repo forbids hardcoded
     addresses in patch logic; the same discipline should apply to host
     tooling). Its unbounded downward scan also needs a lower bound.
2. **Kernel-side targets** (each needs a written reveal procedure before any
   implementation, mirroring the guest patch workflow):
   - Target 1, narrow: flip `csr_active_config` bits at runtime
     (CSR_ALLOW_TASK_FOR_PID, CSR_ALLOW_RESEARCH_GUESTS) so the two `csrutil`
     Recovery commands collapse into the kext-approval trip. Must be validated
     per macOS release — some checks may read boot policy rather than the
     global.
   - Target 2, blunt: flip the AMFI "get out of my way" state at runtime —
     equivalent posture to Path A minus the nvram/reboot, still cdhash-free.
   - Symbols come from the on-disk kernelcache (`kmutil inspect` prints the
     path; release kernelcaches keep symbol tables). KextRW itself provides
     kernel base/slide so no file offsets are needed at runtime.
3. **Distribution and UX**:
   - The kext cannot ship inside `VPhone.bundle` (bundle-admission tier rules;
     it must live in `/Library/Extensions`). Build it like `VPhoneGuestComponents`
     (Makefile, signed ad hoc, pinned by digest) or a small sibling project.
   - The Launchpad helper is already the only root surface and already runs
     receipt-pinned tools; a new verb would verify the kext digest and run
     `kmutil install`, then guide the user through the one-time approval.
     Approved kexts load at every boot, so admission applies automatically per
     boot — no per-build or per-boot user action.
   - `vphone-cli host preflight` grows a Path C probe: kext service present →
     self-test call → report.

## Risks, honestly

- A resident arbitrary-kernel-RW kext is a kernel backdoor keyed only by an
  entitlement string. Trimming selectors and renaming the key is mitigation,
  not elimination. This is strictly worse standing risk than Path B's one
  amfid byte, and roughly Path A's risk class with SIP filesystem protection
  retained.
- Upstream is validated on macOS 15.2 only. macOS 26/27 hosts (including
  `ARM64E.X1` machines) need load validation; kexts remain arm64e, but PAC
  diversity and `OSBundleLibraries` version bumps need checking per release.
- Per-macOS-build symbol reveal becomes a standing maintenance item, the same
  class of work as guest patch retargeting.
- The runtime-writability/effect of the CSR config global is unverified; the
  narrow target may not survive future releases.

## Recommendation

Do not integrate KextRW for the default flow. Path B's pains are better
addressed in place: cdhash churn is a signing/release-engineering problem, and
amfid-layout fragility is contained inside `VPhoneEscalator` (the M6 fix shows
the escalation path works). Keep Path C as an opt-in research-workstation
configuration for users who already run kernel extensions — validated first on
macOS 15 and 26 with both kernel targets' reveal procedures written here —
never as a requirement, and never wired into Launchpad's default preflight
gate.

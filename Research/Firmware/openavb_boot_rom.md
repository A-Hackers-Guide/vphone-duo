# OpenAVB boot ROM

New machines boot [OpenAVB](https://github.com/owngoal-dev/OpenAVB), an
open-source AArch64 boot ROM compatible with AVPBooter, instead of Apple's
`AVPBooter.vresearch1.bin` from Virtualization.framework. This page is
vphone's side of OpenAVB's host contract (`docs/external-contract.md` in its
repository): what the ROM expects, what vphone does about it, what was changed
in OpenAVB to run under Virtualization.framework, and how it was validated.

## Where the ROM lives

| What | Where |
| --- | --- |
| Checked-in image and licences | `VPhoneExecutable/VPhoneVirtualization/Resources/OpenAVB/` |
| Rebuild and check | `VPhoneExecutable/VPhoneVirtualization/Build/UpdateOpenAVB.sh` (Homebrew LLVM and LLD, outside the repository) |
| In the bundle | `VPhone.bundle/Contents/Resources/OpenAVB/OpenAVB.bin`, admitted by `ValidateBundle.sh` |
| In a machine | `<vm>/OpenAVB.bin`, named by `romImages.avpBooter` in `config.plist` |
| Recognition | `VPhoneBootROM` (VPhoneCoreKit): an image containing `OpenBootROM:` is OpenAVB, anything else Apple's |

`vm new` copies the bundle's OpenAVB (`VPhoneBundleOperations.defaultROMSource`).
A machine cloned from a template gets the creating bundle's OpenAVB too
(`VPhoneVirtualMachineCreator.cloneFromTemplate`): the ROM is not part of a
template's key, because it changes without a restore. `vm config --rom
openavb|apple|<file>` switches an existing machine from its next start; the ROM
it replaces stays in the folder, so an Apple ROM keeps its digest patch. `vm
new --rom apple` still creates a machine on Apple's ROM. The PCC GPU recovery
machine (`VPhonePCCGPURecovery`) keeps Apple's ROM: it restores Apple-signed
PCC firmware, which OpenAVB has not been tried with.

## What changes on the boot chain

**AVPBooter patch.** OpenAVB checks no image digest, so
`avpbooter-boot-dgst_bypass` has nothing to patch on a machine that boots it.
`fw patch` reads the ROM kind from the manifest and drops the AVPBooter
component (`FirmwarePipelineComponents.swift`), logging
`Boot ROM: OpenAVB, which needs no ROM patch`. The patch stays selected and
planned, which is what the machine behaves as, so `fw patches` shows no drift
for it.

**Normal boot.** OpenAVB reads LLB from the firmware block device, checks the
IMG4 container and that a manifest is present, publishes the manifest's
SHA-384 for iBoot's LocalPolicy path and hands off. A plaintext payload (what
`fw patch` writes for LLB) is copied to its resident window at `0x70074000`
and relocates itself. No patch table is needed: the LLB is already patched.
Because both ROMs load the same LLB, a machine restored on Apple's ROM boots on
OpenAVB unchanged.

**DFU.** OpenAVB carries no description of any iBoot build. It refuses a DFU
iBSS unless the host first uploads the image's identity into patch-store
stage 0: the IM4P payload's size and SHA-256, the decoded image's size and
SHA-256, the load base and the entry exception level. `vphone-cli restore`
does this before it sends iBSS (`MobileRestoreCore/Recovery/openavb.c`, called
from `dfu_send_component`):

1. Probe with the read-only report request (`0xc0`, `0x73`, 48 bytes). Apple's
   ROM stalls it, and then nothing is written.
2. Build the 112-byte `AVPPatchStageHeader` from the personalized iBSS: walk
   IMG4 → IM4P → first OCTET STRING, require `bvx2`, decode it with
   libcompression, read iBoot's link base from offset `0x300` (`0x7006c000` for
   vresearch101), entry level 2, identity flag, no rows.
3. Open (`0x41 0x70`), append one chunk (`0x41 0x71`), seal with 0 rows
   (`0x41 0x72`), then report again and require stage 0 `{0, 112, sealed}`.

OpenAVB decodes only LZFSE, so `fw patch` now writes iBSS back LZFSE-compressed,
as Apple ships it (`IM4PHandler.lzfseFourCCs`); Apple's ROM takes that too.
Every other image is still written back as before.

iBEC and everything later are loaded by iBSS, not by the ROM, and are
unaffected. OpenAVB's iBoot handoff diversion (patch rows that branch into
`0x170000`, the `SCRATCH` page at `0x160000`, `BOOT_ARGS_EXTRA` at `0x161000`)
is not used: vphone's iBoot is patched in the image.

## Changes to OpenAVB for Virtualization.framework

OpenAVB's first commit, `54b67bf`, was written against hosts that map the ROM
aperture as RAM and model the platform differently, and under
Virtualization.framework it did not start. Five changes made it boot and
restore. vphone carried them as patches until upstream took them in
[owngoal-dev/OpenAVB#1](https://github.com/owngoal-dev/OpenAVB/pull/1),
merged as `02ca2e5`. Upstream then rewrote `main` into one commit, `115169e`,
which keeps those changes and builds the same image the patched `54b67bf`
did. A sixth change, found later, went upstream in
[owngoal-dev/OpenAVB#2](https://github.com/owngoal-dev/OpenAVB/pull/2) as
`3c7e7f6`. A seventh went upstream in
[owngoal-dev/OpenAVB#3](https://github.com/owngoal-dev/OpenAVB/pull/3) as
`65a776e`, which is the pin. Each change
was found on a live machine by the first thing that stopped, in this order:

1. **ROM aperture is read-only.** `_start` stores `avp_el2_present` at
   `ROM_LIMIT - 16` (`0x17fff0`). The store took a synchronous external abort
   (ESR `0x97130050`, ELR `0x1000f8`, FAR `0x17fff0`) and the ROM parked in
   `pvpanic_trigger` with no console output. The byte now lives in the last
   16 bytes of the patch-store window, which nothing clears.
2. **Chip ID register reads 0.** `platform_read_identity` reads the chip ID at
   `0x4006f0`, which Virtualization.framework leaves at 0. DFU enumerated as
   `CPID:0000` and idevicerestore stopped at "Unable to discover device type".
   It now falls back to `0xfe01`, as Apple's ROM reports. Board ID, ECID,
   security domain and chip revision were already right.
3. **DFU suffix CRC.** `validate_transport` computed the suffix CRC with the
   register seeded with 0 and inverted at the end; libirecovery seeds it with
   all ones and sends it uninverted (the DFU 1.1 form, which Apple's ROM
   takes). Every image was refused before its container was read, with no
   diagnostic, and the ROM stayed in DFU, so idevicerestore went on to send
   iBEC into the same buffer. The libirecovery form is accepted too.
4. **Remote boot bit.** iBSS reads bit 5 of the boot context word at
   `0x400300` as "Remote boot" (`0x70085b74` in the 23G90 iBSS: `ldr w8,
   [0x400300]; ubfx w0, w8, #5, #1`). Apple's ROM sets it for a DFU image;
   OpenAVB did not, so iBSS printed "Local boot" and panicked at the recovery
   prompt. The DFU handoff now sets it.
5. **USB device left running.** OpenAVB reposts a queue-0 event buffer after
   every response, so at the handoff the device still held one, in RAM the
   handoff clears. iBSS then panicked in its USB event loop
   (`4d682d940d6c950:514`: an event record whose type byte is not 1, 2 or 3).
   The handoff now writes the device's two enable registers (`+0x404`,
   `+0x400`) back to 0, and iBSS initializes it itself.
6. **SEP not ready after a warm reset** (owngoal-dev/OpenAVB#2, carried as a
   patch until it was merged). A guest reboot is a PSCI `SYSTEM_RESET`, which restarts
   the SEP together with the AP. Cold boots and restores worked, but every
   guest reboot hung: the console filled with `SEP RX timeout`, and
   Launchpad's setup boot failed at "the guest did not come back from the
   reboot within 300 s". Tracing the mailbox registers (`+0x10`, `+0x14`,
   `+0x1c`, `+0x20`) on the console showed the order. On a cold start the SEP
   is already up when OpenAVB takes the slot, and its first message is
   waiting (`1c=00100000`). After a warm reset OpenAVB is faster: it takes the
   slot with RX empty and sends at once (`20=00100000`). The mailbox drops the
   request (`coprocessor.mailbox: Failed to send a message` in the
   VirtualizationCore log). The SEP's own setup then clears the AP's ownership
   (`14=00000000`), and the SEP ROM spins in its acquisition loop
   (`0x200b14c`) while OpenAVB waits for an answer. `sep_initialize` now waits,
   for at most 5 s, for the SEP's first message before anything is sent,
   taking the slot back if the SEP's restart drops it. Each request also sets
   the enable bit at `+0x10` first, as AVPBooter's acquire loop (`0x110c48`)
   and the SEP ROM do. On a cold start the message is already there, so
   nothing waits. Clearing work RAM at reset, re-requesting a stale-owned
   slot, and AVPBooter's "not full" send predicate were each tried and are
   not needed.

7. **SIDP block on a small guest** (owngoal-dev/OpenAVB#3, carried as a
   patch until it was merged). Before LLB
   runs, `source_image_publish_boot_manifest` writes the LLB manifest's
   SHA-384 into the t8110 SIDP block (`0x2_3D2E_0044`, `+0x74`, `+0x84`).
   Virtualization.framework maps nothing there unless the guest has about
   7.5 GiB of memory or more, the same threshold as OpenSEP's warm-boot mark
   and DART (`opensep_sep_rom.md`). On a 6144 MB iPhone17,3 iOS 27.0.1
   machine the first read of `+0x84` aborted right after `iLLB container
   accepted`; the AP sat in `pvpanic_trigger` with x19 = `0x2_3D2E_0084`, the
   SEP waited in its mailbox, and `vm create`'s first boot check timed out.
   The 2026-10-18 validation ran on 8192 MB machines, where the block is
   guest RAM. The vresearch101 iBoot boots on Apple's ROM, which publishes
   nothing there, so the patch skips the publish when the chip ID register
   reads 0, as it does under Virtualization.framework (change 2).

**How these were found.** The VM's GDB stub (the lower of the two ports
`lsof -iTCP -sTCP:LISTEN` shows for the `com.apple.Virtualization.VirtualMachine`
XPC process) reads registers and memory: the AP's PC, ESR/ELR/FAR, OpenAVB's
progress words at `0x400064`, the patch store at `0x71200000` and the upload
buffer at `0x71000000`. Symbolize ROM addresses with OpenAVB's
`build/OpenAVB.elf`. Hardware breakpoints wedged the stub, so iBSS was read
statically (decode the IM4P, find the code that loads a string with ADRP+ADD,
disassemble with `llvm-mc`). OpenAVB's own diagnostics (`OpenBootROM: …`)
reach the VM's serial log.

## Validation

- 6144 MB (2026-10-19, change 7 and OpenSEP's two patches): an iPhone17,3
  iOS 27.0.1 machine boots on OpenAVB and OpenSEP, vphoned answers 13 s after
  launch, and three guest reboots come back in 9 to 10 s
  (`opensep_sep_rom.md` has the run).

- Normal boot: an iPhone17,3 iOS 26.6.2 machine restored on Apple's ROM, with
  `romImages.avpBooter` pointed at OpenAVB, prints `OpenBootROM: SEP bootstrap
  complete`, `Loaded LLB` and iBoot, and vphoned answers `device.info`.
- Restore (2026-10-18): an iPhone17,3 iOS 26.6.2 machine whose `fw patch` ran
  on this bundle (`Boot ROM: OpenAVB`, 8 components, iBSS saved LZFSE) restores
  through OpenAVB's DFU with this bundle's `vphone-cli restore`: `Describing
  iBSS to OpenAVB (payload 374347 bytes, image 740704 bytes at 0x7006c000)`,
  the ROM logs `iBSS compressed identity accepted` and `raw identity
  accepted`, iBSS and iBEC print `Remote boot`, and the restore ends `Restore
  Finished` with 86 boot-chain patches in the receipt.
  With CFW installed it boots to iOS on OpenAVB and vphoned answers.
- Guest reboot (2026-10-18, with change 6): `system.reboot` on that machine
  comes back in 10 s, three times out of three, with no `SEP RX timeout`.
  `vm template setup` (Launchpad's setup boot, which failed at its reboot
  step without the patch) passes, the reboot taking 9 s. A second full DFU
  restore on the patched image also ends `Restore Finished`.
- Unit tests: `OpenAVBIdentityTests` (VPhoneRestoreTests) pin the header
  layout and refusals; `BootROMTests` (VPhoneCoreKitTests) the naming, the
  switch and the report; `FirmwarePipelineTests` the AVPBooter skip;
  `IM4PPayloadParityTests` the LZFSE iBSS.

To check the image after an update: `UpdateOpenAVB.sh` with no argument
rebuilds the pinned commit, plus any patches in `patches/`, and compares byte
for byte. To check a
machine: `vphone-cli vm info <vm>` prints `rom:`, and the first lines of a boot
log show `OpenBootROM:` for OpenAVB.

## Upstream

All seven changes are upstream: 1 to 5 in owngoal-dev/OpenAVB#1 (folded into
`115169e`), 6 in owngoal-dev/OpenAVB#2, 7 in owngoal-dev/OpenAVB#3. vphone
carries no patch. The pin is #3's own commit, `65a776e`, not its merge
`234a080`: both have the same tree and `main` reaches both, but upstream has
rewritten `main` once, and GitHub keeps a PR's head commit reachable
(`refs/pull/3/head`) after a rewrite. If
upstream rewrites `main` again, `UpdateOpenAVB.sh` fails at checkout; move the
pin to the rewritten commit that builds the same image.

A change upstream has not taken yet goes in `Resources/OpenAVB/patches/` as a
`git format-patch` file; delete it when the pin moves past it.
`UpdateOpenAVB.sh` refuses a patch that no longer applies.

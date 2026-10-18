# OpenSEP SEP ROM

New machines start their SEP core from
[OpenSEP](https://github.com/owngoal-dev/OpenSEP), an open-source SEP boot ROM
compatible with AVPSEPBooter, instead of Apple's `AVPSEPBooter.vresearch1.bin`
from Virtualization.framework. It goes with [OpenAVB](openavb_boot_rom.md) on
the AP side: with both, nothing Apple wrote runs before iBoot and SEPOS. This
page is vphone's side of OpenSEP's host contract (`docs/external-contract.md`
in its repository): what the ROM expects, what vphone does about it, and how it
was validated.

## Where the ROM lives

| What | Where |
| --- | --- |
| Checked-in image and licence | `VPhoneExecutable/VPhoneVirtualization/Resources/OpenSEP/` |
| Rebuild and check | `VPhoneExecutable/VPhoneVirtualization/Build/UpdateOpenSEP.sh` (Homebrew LLVM and LLD, outside the repository) |
| In the bundle | `VPhone.bundle/Contents/Resources/OpenSEP/OpenSEP.bin`, admitted by `ValidateBundle.sh` |
| In a machine | `<vm>/OpenSEP.bin`, named by `romImages.avpSEPBooter` in `config.plist` |
| Recognition | `VPhoneSEPROM` (VPhoneCoreKit): an image containing `AVPSEPBooter-` (Apple's version string) is Apple's, anything else OpenSEP |

OpenSEP prints nothing and carries no string of its own, so recognition is the
reverse of OpenAVB's: Apple's ROM is the one with a marker. `ValidateBundle.sh`
refuses a bundled `OpenSEP.bin` that carries Apple's marker or exceeds the SEP
ROM window (`0x29000` bytes, the size of Apple's image).

`vm new` copies the bundle's OpenSEP (`VPhoneBundleOperations.defaultSEPROMSource`).
A machine cloned from a template gets the creating bundle's OpenSEP too
(`VPhoneVirtualMachineCreator.cloneFromTemplate`), as it gets OpenAVB: the SEP
ROM is not part of a template's key, and a machine changes SEP ROM without a
restore (see Validation). `vm new --seprom apple` still creates a machine on
Apple's ROM, and
`vm config --seprom opensep|apple|<file>` switches an existing machine from its
next start; the ROM it replaces stays in the folder. `vm info` prints
`seprom:` and its JSON carries `sepROM`. The PCC GPU recovery machine
(`VPhonePCCGPURecovery`) keeps both of Apple's ROMs.

## The build

`make PLATFORM=vresearch1 build/OpenSEP.bin` at the pinned commit, with no
patches. `vresearch1` is OpenSEP's default and the row of its handoff table
that stands in for Virtualization.framework's AVPSEPBooter: the SEPOS runtime
is entered at the runtime region's base (`0x06000000`) with the handoff pointer
in `x0`, `x1` zero, and the firmware building its own translation tables. The
other row, `t8110`, is for the iphone-cli QEMU machine and is not built here.
OpenSEP's `docs/platforms.md` cites the AVPSEPBooter addresses each value of
the `vresearch1` row was read from (macOS 26's image, SHA-256 `86d008eb…`, the
one this Mac's Virtualization.framework ships).

The image is 147496 bytes and builds byte for byte the same from a fresh clone
(`UpdateOpenSEP.sh` with no argument).

## What changes on the boot chain

Nothing vphone patches. Apple's AVPSEPBooter was never patched either, and
`fw patch` has no SEP ROM component. The SEP firmware itself
(`sep-firmware.vphone600.RELEASE.im4p`, sent as `RestoreSEP` during a restore
and loaded by iBoot at boot, `sepfw-load-at-boot = 1`) stays as it was.

- **Mailbox.** OpenSEP serves the same mailbox protocol as AVPSEPBooter: the
  startup events (`0xd2`), the session opcodes the AP's ROM and iBoot send,
  and opcode `0x06`, with which the AP kernel's `AppleSEPManager` publishes
  the SEP firmware's dart-sep IOVA. OpenAVB's SEP bootstrap
  (`OpenBootROM: SEP bootstrap complete`, and in DFU `DFU SEP finalized`) talks
  to it unchanged.
- **Research seed.** OpenSEP answers the seed requests (opcodes `0x03`/`0x04`,
  `0x21`/`0x22`) with the constant `0xdeadbeef` pattern
  (`sep_fill_research_seed_pattern`, `src/protocol/protocol.c`), so the seed is
  the same on every machine. The per-machine secret is the one SEPOS keeps in
  `SEPStorage` ([machine identity](../Host/machine_identity_and_clone.md)),
  which neither ROM touches.
- **Image trust.** OpenSEP evaluates the SEP firmware manifest's certificate
  chain against the Apple DDI Secure Boot Root CA - G1 it carries, logs the
  result and goes on: its build does not set
  `OPEN_SECURE_ROM_ENFORCE_IMAGE_TRUST`. The `vphone600` firmware is not
  encrypted, so OpenSEP's table of iPhone14,4 firmware keys is never used here.
- **Warm boot.** OpenSEP's reset path checks a warm-boot word at
  `0x2_3D2E_4804` that only the t8110 runtime writes. OpenSEP's own docs say
  the path is unexercised on `vresearch1`; guest reboots, which restart the SEP
  with the AP, come back (see Validation), so the SEP starts cold there.

## Validation

All on 2026-10-18, iPhone17,3 iOS 26.6.2 / cloudOS 26.4 (23E5207q), on a
bundle with this change installed beside the default (`--keep-default`).

- Restore: a machine created with `vm create --no-template` (`OpenAVB.bin` and
  `OpenSEP.bin` in the folder) restores through OpenAVB's DFU:
  `Sending RestoreSEP (3299082 bytes)`, `AppleSEPBooter: SEP accepted IMG4` in
  the restore ramdisk, `Restore Finished`. CFW installs. The pre-CFW boot after
  the restore panics with `initproc failed to start … libSystem.B.dylib`, as
  it does on Apple's ROMs (the guest has no CFW yet).
- Boot and setup: the setup boot passes (settle 62 s, its reboot 9 s); the
  guest unlocks and SpringBoard runs.
- Guest reboots: `system.reboot` (`force: true`) comes back in 12, 12 and 13 s,
  three times out of three, with no `SEP RX timeout` or SEP panic on the
  console.
- Switching: that machine, restored on OpenSEP, boots on Apple's SEP ROM after
  `vm config --seprom apple` (unlocks, SpringBoard runs) and again on OpenSEP
  after `--seprom opensep`. A machine cloned from a template built on Apple's
  SEP ROM boots on OpenSEP after `--seprom opensep` and comes back from a
  reboot in 12 s. With the template clone change, a fresh clone of that
  template gets `OpenSEP.bin` (`vm info --json`: `"sepROM":"opensep"`) and
  passes its first-boot check.
- Unit tests: `SEPROMTests` (VPhoneCoreKitTests) pin the recognition, the
  naming in a new machine, the switch in both directions and the report, and
  check the framework's image is recognised as Apple's.

To check the image after an update: `UpdateOpenSEP.sh` with no argument
rebuilds the pinned commit and compares byte for byte. To check a machine:
`vphone-cli vm info <vm>` prints `seprom:`.

## Upstream

No patches are carried. If one is needed, it goes in
`Resources/OpenSEP/patches/` as a `git format-patch` file until upstream takes
it; `UpdateOpenSEP.sh` refuses a patch that no longer applies.

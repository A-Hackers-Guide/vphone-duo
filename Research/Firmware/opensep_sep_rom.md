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
patches. The pin, `8b1633f`, is the head of owngoal-dev/OpenSEP#1, which
fixed the warm-boot check and the DART walk below. `vresearch1` is OpenSEP's default and the row of its handoff table
that stands in for Virtualization.framework's AVPSEPBooter: the SEPOS runtime
is entered at the runtime region's base (`0x06000000`) with the handoff pointer
in `x0`, `x1` zero, and the firmware building its own translation tables. The
other row, `t8110`, is for the iphone-cli QEMU machine and is not built here.
OpenSEP's `docs/platforms.md` cites the AVPSEPBooter addresses each value of
the `vresearch1` row was read from (macOS 26's image, SHA-256 `86d008eb…`, the
one this Mac's Virtualization.framework ships).

The image is 147512 bytes and builds byte for byte the same from a fresh clone
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
  `0x2_3D2E_4804` that only the t8110 runtime writes, and the initial
  import (`39ff3d7`) did it on `vresearch1` too. Virtualization.framework maps nothing at that
  IPA unless the guest has about 7.5 GiB of memory or more (measured on macOS
  27.0.1 26A434: DFU came up at 7680 and 8192 MB, never at 4096, 6144 or
  7168 MB). Below that the load is the SEP core's first fault: VBAR_EL1 is
  still 0, it lands at `0x200`, and the framework's SEP process ends with
  `Unhandled exception code` about 130 ms after it starts (a crash report of
  `com.apple.Virtualization.VirtualMachine` with only `cpu-0` and
  `virtual-clock` threads). The AP's ROM, OpenAVB or Apple's, then spins in
  its mailbox acquire, `vm launch --dfu` says the VM started, and
  `recovery-probe` never finds it. Single-stepping the SEP core through its
  GDB stub stops on that load. Since `ef26920` (owngoal-dev/OpenSEP#1) the check is left out
  of the `vresearch1` build, which then always starts cold; guest reboots,
  which restart the SEP with the AP, come back cold anyway (see Validation).
  Above the threshold the IPA is guest RAM, so the unpatched check could also
  read a stale `1` and take the warm path.
- **DART.** OpenSEP translated every address that arrives over the mailbox
  through dart-sep's stream zero, reading its TCR and TTBR at IPA
  `0x2_5D2C_0000`, the t8110 DART. That IPA has the same threshold. With the
  warm-boot fix alone a 6144 MB iPhone17,3 iOS 27.0.1 machine came up in
  DFU, took iBSS, iBEC, the ramdisk and `RestoreSEP`, entered restore mode,
  and lost restored right after NORData (`Could not read data (-256)`), with
  no crash report from the framework (by then OpenSEP's own vector table is
  set, so a fault there would end in OpenSEP's panic path; that was not
  observed directly). With the DART fix too, the same restore finishes. On
  the 8 GiB machines of the first validation the read was guest RAM that
  still read zero, so the walk took the stream as unprogrammed and used the
  address as it is. Since `8b1633f` (owngoal-dev/OpenSEP#1) that is the `vresearch1`
  behaviour.

## Validation

All on 2026-10-18, iPhone17,3 iOS 26.6.2 / cloudOS 26.4 (23E5207q), on a
bundle with this change installed beside the default (`--keep-default`), on
machines with the default 8192 MB of memory and the unpatched image. That is
above the warm-boot threshold, which is why none of it saw the failure; the
Mac fleet's 6144 MB staging machines did.

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

### 6144 MB, with both fixes (2026-10-19)

On this Mac (M5 Pro, macOS 27.0.1 26A434), iPhone17,3 iOS 27.0.1 (24A446) /
cloudOS 26.4 (23E5207q), 6 CPU, 6144 MB, `vm create --no-template` from a
build of vphone upstream `61b4efb2` with both fixes, as patches then (the image is the one `8b1633f` builds, `92690b9c…`):

- DFU comes up through OpenAVB, the restore ends `Restore Finished`, CFW
  installs.
- The first boot check timed out. The SEP core was waiting in
  `sep_mailbox_receive_slot`; the AP was parked in OpenAVB's
  `pvpanic_trigger` after `prepare_virtual_firmware_illb`, with x19 at
  `0x2_3D2E_0084`. OpenAVB's `source_image_publish_boot_manifest` reads and
  writes the t8110 SIDP window at `0x2_3D2E_0044`…`0x84`, in the same unbacked
  range. That is OpenAVB's, not OpenSEP's; vphone carries a patch for it
  (`openavb_boot_rom.md`, change 7).
- The same machine after `vm config --rom apple` (Apple's AVPBooter, OpenSEP
  kept): iOS boots, AppleSEPKeyStore loads the keybag and the data volume
  unlocks, vphoned answers `device.info` (`ios_version` 27.0.1,
  `memory_bytes` 6418317312), and `system.reboot` (`force: true`) comes back
  in about 10 s with no `SEP RX timeout` or SEP panic on the console.

- The same machine back on OpenAVB with its patch (image `bbcabe73…`) and
  OpenSEP: `iLLB container accepted`, `virtual firmware prepared`, iBoot and
  iOS boot, vphoned answers `device.info` 13 s after launch, and three
  `system.reboot` (`force: true`) come back in 10, 9 and 10 s, with no
  `SEP RX timeout` or panic on the console.

- A template the way the Mac fleet builds one (`plan_template.go`), on the
  final images (OpenAVB `bbcabe73…`, OpenSEP `92690b9c…`): `vm new
  template-… --cpu 6 --memory 6144`, `fw prepare`, `fw patch --preset
  standard`, `vm launch --dfu` (the first `recovery-probe` answered),
  `restore` (`Restore Finished`), `cfw install`, `vm template trim --tier
  standard`, `vm template setup --slim on --strict` (settle 64 s, its reboot
  13 s), `vm template adopt` (template `99538dfad74f`, not stale). A clone,
  `vm create --template … --cpu 6 --memory 6144`, boots on OpenAVB and
  OpenSEP: vphoned answers 15 s after launch, three `system.reboot` come back
  in 11, 13 and 15 s, with no `SEP RX timeout` or panic. `vm create` with a
  template does not reproduce the fleet here: it builds the template's staging
  machine at 8 CPU and 8192 MB whatever `--memory` says
  (`VPhoneVirtualMachineCreator.buildTemplate`), above the threshold.

Not covered: iPad guests, other iOS versions, and the Mac fleet's own hosts
(M4, the fleet's `tunnel` network).

## Upstream

Both fixes above are upstream in owngoal-dev/OpenSEP#1, and vphone carries no
patch. The pin is the PR's head, `8b1633f`, which `main` reaches through the
merge `74b2359` (same tree). A change upstream has not taken yet goes in
`Resources/OpenSEP/patches/` as a `git format-patch` file until it is merged;
`UpdateOpenSEP.sh` refuses a patch that no longer applies.

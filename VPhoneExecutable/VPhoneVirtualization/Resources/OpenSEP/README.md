# OpenSEP

`OpenSEP.bin` is the SEP boot ROM new machines run instead of Apple's
`AVPSEPBooter.vresearch1.bin`. It is
[OpenSEP](https://github.com/owngoal-dev/OpenSEP), an open-source SEP boot ROM
compatible with AVPSEPBooter, built from source for the `vresearch1` platform.
`StageBundle.sh` copies the image and its licence to
`VPhone.bundle/Contents/Resources/OpenSEP/`, and `vm new` copies the image into
each new machine folder.

| | |
| --- | --- |
| Source | `https://github.com/owngoal-dev/OpenSEP` |
| Commit | `39ff3d7572059668077388dd907b63308ddf645e` |
| Patches | `patches/*.patch`, applied in order (two, see below) |
| Target | `make PLATFORM=vresearch1 build/OpenSEP.bin` |
| Toolchain | Homebrew LLVM 23.1.3 (`clang`, `llvm-objcopy`), Homebrew LLD 23.1.3 |
| SHA-256 | `92690b9c7e900ec0054271dbbc0444ee2d8567c8d41d3a2e491ba011e2b08b12` |
| Size | 147512 bytes (the SEP ROM window is `0x29000`, 167936) |

The image is checked in rather than built by the `VPhone` scheme, so building
the bundle needs no cross toolchain. To move to another commit, or to check
that this file is what the commit builds, run
`VPhoneExecutable/VPhoneVirtualization/Build/UpdateOpenSEP.sh` (see its
header). It clones and builds outside the repository and needs
`brew install llvm lld`.

## Patches

- `0001-Check-the-warm-boot-mark-on-t8110-only.patch`. The reset path reads
  a warm-boot mark at IPA `0x2_3D2E_4804` that only the t8110 runtime writes.
  Virtualization.framework maps nothing there for a guest with less than about
  7.5 GiB of memory, so the load aborts before the vector table is set, the
  framework ends the SEP core (`Unhandled exception code`) and the AP's ROM
  waits for the mailbox forever: DFU never comes up. The patch leaves the
  check out of the `vresearch1` build. Proposed upstream in
  [owngoal-dev/OpenSEP#1](https://github.com/owngoal-dev/OpenSEP/pull/1).
- `0002-Walk-the-DART-on-t8110-only.patch`. Mailbox addresses were translated
  through the t8110 DART, whose registers OpenSEP reads at IPA
  `0x2_5D2C_0000`. Under the same memory threshold that read aborts inside
  OpenSEP's own vector table during the first image copy of a restore, the
  SEP panics, and restored drops the connection right after NORData. The
  `vresearch1` build now uses the addresses as they are. Proposed upstream in
  [owngoal-dev/OpenSEP#1](https://github.com/owngoal-dev/OpenSEP/pull/1).

If vphone needs a change upstream has not taken yet, put it in
`patches/` as a `git format-patch` file. `UpdateOpenSEP.sh` applies patches in
order and refuses one that no longer applies. Delete a patch once the pin
moves past it.

## Licence

`LICENSE` is OpenSEP's licence as published at that commit: MIT. The image
also carries two pieces of public Apple data, as OpenSEP's README describes:
the Apple DDI Secure Boot Root CA - G1 certificate, and a table of published
per-build SEP firmware keys for iPhone14,4 that a `vresearch1` machine does not
use (its `vphone600` SEP firmware is not encrypted).

What the ROM expects from the host (memory map, mailbox, SEP firmware image)
and how vphone uses it is described in `Research/Firmware/opensep_sep_rom.md`.

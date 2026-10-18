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
| Patches | `patches/*.patch`, applied in order (none) |
| Target | `make PLATFORM=vresearch1 build/OpenSEP.bin` |
| Toolchain | Homebrew LLVM 23.1.3 (`clang`, `llvm-objcopy`), Homebrew LLD 23.1.3 |
| SHA-256 | `fe3f8de4334dd00ba6862bd95cd86d9bea7534e47592432a601d815edfb911d6` |
| Size | 147496 bytes (the SEP ROM window is `0x29000`, 167936) |

The image is checked in rather than built by the `VPhone` scheme, so building
the bundle needs no cross toolchain. To move to another commit, or to check
that this file is what the commit builds, run
`VPhoneExecutable/VPhoneVirtualization/Build/UpdateOpenSEP.sh` (see its
header). It clones and builds outside the repository and needs
`brew install llvm lld`.

## Patches

None. If vphone needs a change upstream has not taken yet, put it in
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

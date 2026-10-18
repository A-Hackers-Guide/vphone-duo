# OpenAVB

`OpenAVB.bin` is the boot ROM new machines run instead of Apple's
`AVPBooter.vresearch1.bin`. It is
[OpenAVB](https://github.com/owngoal-dev/OpenAVB), an open-source AArch64
boot ROM compatible with AVPBooter, built from source. `StageBundle.sh` copies
the image and its licences to `VPhone.bundle/Contents/Resources/OpenAVB/`, and `vm new` copies
the image into each new machine folder.

| | |
| --- | --- |
| Source | `https://github.com/owngoal-dev/OpenAVB` |
| Commit | `3c7e7f602d2d35af67f50454a8216337f35b11bb` |
| Patches | none (`patches/*.patch`, applied in order, when there are any) |
| Target | `make build/OpenAVB.bin` |
| Toolchain | Homebrew LLVM 23.1.3 (`clang`, `llvm-objcopy`), Homebrew LLD 23.1.3 |
| SHA-256 | `d63ea62226d4383288a5a36c440aa2d1df8cccabe0118cac0ab2e0c23ba4c3d2` |
| Size | 460057 bytes |

The image is checked in rather than built by the `VPhone` scheme, so building
the bundle needs no cross toolchain. To move to another commit, or to check
that this file is what the commit builds, run
`VPhoneExecutable/VPhoneVirtualization/Build/UpdateOpenAVB.sh` (see its
header). It clones and builds outside the repository and needs
`brew install llvm lld`.

## Patches

None. OpenAVB's first commit, `54b67bf`, did not run under
Virtualization.framework. Five changes found on live machines made it boot and
restore, and upstream took them in
[owngoal-dev/OpenAVB#1](https://github.com/owngoal-dev/OpenAVB/pull/1), now
part of `115169e`. A sixth let a guest reboot: after a reboot the SEP restarts
together with the ROM, a request sent before it was up was dropped, and every
reboot hung, so the ROM now waits for the SEP's first message before sending.
Upstream took it in
[owngoal-dev/OpenAVB#2](https://github.com/owngoal-dev/OpenAVB/pull/2). The pin
is that PR's commit, `3c7e7f6`, which `main` reaches through the merge
`63c1ead` (same tree), rather than the merge itself.
`Research/Firmware/openavb_boot_rom.md` has the evidence for each change.

If vphone needs a change upstream has not taken yet, put it in `patches/` as a
`git format-patch` file. `UpdateOpenAVB.sh` applies patches in order and
refuses one that no longer applies. Delete a patch once the pin moves past it.

## Licence

`LICENSE` is OpenAVB's licence as published at that commit: MIT for OpenAVB's
own code, with the third-party notices it lists. A few files built into the
image are APSL-2.0 (`APSL-2.0.txt`); their modified source is the public
repository above.

What the ROM expects from the host (the patch store, the stage-0 image
identity uploaded before iBSS, LZFSE payloads) is described in
`Research/Firmware/openavb_boot_rom.md`.

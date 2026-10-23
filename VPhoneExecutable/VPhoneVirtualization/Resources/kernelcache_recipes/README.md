# Kernelcache recipes

Only the 26.1–26.4 beta cloudOS releases ship vphone600 components. On any
other cloudOS, `fw patch` takes the research board's (vresearch101) and rebuilds
its `kernelcache.release.vresearch101` with the iPhone virtualisation kexts of a
donor kernelcache (`kernel-boot-vresearch101_kext_mix`, `KernelCacheMixer`).
These recipes say how, one per supported kernelcache. Details are in
`Research/0_binary_patch_comparison.md` ("The research board's kernelcache").

## Layout

```
bases/<iOS version>_<iPhone build>/
  manifest.json      the recipe (below)
  symbols.json.gz    symbol map: kernelcache address (decimal) to name(s)
  kexts.txt          bundle identifiers of the mix
donors/<id>/
  manifest.json      the donor kernelcache and the cloudOS it is read from
  symbols.json.gz    symbol map, for a stripped donor
```

Base `manifest.json`:

| Key | Meaning |
|---|---|
| `kernel.sha256`, `kernel.decompressedSHA256` | identify the research board kernelcache (IM4P or decompressed) |
| `kernel.kdk` | the KDK its extraction makes; a kernelcache whose kexts carry no `DTPlatformBuild` (26.6, 26.7) takes the build from here |
| `donor` | `donors/<id>`, which supplies the virtualisation kexts |
| `builderLayout` | `kernel-last` (iOS 26.4+, kmutil of macOS 26.4+) or `kernel-first` |

The bundle list is the base's kexts without the research-board-only ones
(CIOMesh, MLX5, Thunderbolt, RDMA, ...), plus the donor kexts that link against
the base kernel.

The donor `vphone600_26.4_23E5207q` is the vphone600 kernelcache of the 26.4
beta cloudOS, the last one with vphone600 components. Only that file is read
from the cloudOS IPSW, once, and kept with its extraction in
`~/.vphone/kernelcache/donors`.

The iOS 18 bases (18.1 to 18.7.2, the research board kernels of their own
release's cloudOS) take their kexts from `vphone600_26.1_23B78`, the vphone600
kernelcache of the public cloudOS 26.1. Mixing across versions cannot go by
name: each donor import was resolved by code identity in every base, and both
maps carry the names those targets have. 18.1 to 18.3.1 leave out the audio
kexts whose imports have no counterpart there (15 donor kexts instead of 18).

## Requirements

- An `ipsw` with `kernel extract --kdk` (blacktop/ipsw), named by `VPHONE_IPSW`.
  vphone-cli does not ship it, and runs it only as the invoking user.
- Root for the link: kmutil only reads kexts owned by root:wheel, and links the
  host's own kexts in place of any others without a word.
- A kmutil of the base's `builderLayout`: macOS 26.4 or later for the iOS 26 bases,
  macOS 15 or 26.0 to 26.3 for the iOS 18 ones. A Mac with the other layout
  links over ssh on one that has it (`VPHONE_KMUTIL_SSH`, see
  `Documents/Guides/create-and-run.md`).

`vphone-cli fw kernelcache <vm>` stages the mix as the user (the extractions
and the volume, in `~/.vphone/kernelcache/staged`), and under sudo links it:
root copies the volume into a directory of its own, refusing any link out of
it, and runs kmutil on the copy. `fw patch` then takes the mix from the cache;
run as `sudo VPHONE_IPSW=<ipsw> vphone-cli fw patch` it does both itself.

Mixed kernelcaches are cached in `~/.vphone/kernelcache/mix`, keyed by the recipe,
with kmutil's log beside each. Remove `~/.vphone/kernelcache` to rebuild them.

kmutil records the absolute path of every codeless kext, so the volume is linked
at a path as long as the build root Apple linked the base in, read from the
base. The mix then does not depend on where it is built.

## Adding a base

A recipe comes from research, not from this repository:

1. Symbolicate the stripped kernelcache with BinDiff against a symbolicated KDK of
   the same family (`ipsw kernel symbolicate --bindiff <kdk> <kc> --json
   --aliases`, which writes every name of an address, as step 4 needs).
2. Fix wrong binds, checked against link symbols, PAC discriminators,
   same-generation macOS KDKs and C++ vtables, until every donor import binds
   and the extraction links.
3. Check the base: its extraction, linked again with Apple's bundle list, must be
   byte-identical to the shipped kernelcache.
4. For a stripped donor, put the import names of the donor extraction the maps
   were built against first in its map. Several names often share an address
   (folded stubs, inherited `_kc.` placeholders), and an import binds to the
   first one; another order makes kmutil fail with "could not find a kext which
   exports this symbol".
5. Build the mix, boot it, and add the map, bundle list and manifest here.

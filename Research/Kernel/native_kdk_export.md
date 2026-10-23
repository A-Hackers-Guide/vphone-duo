# Native KDK Mach-O export

`KDKImageExport` converts one kernel-collection fileset image into a standalone
ARM64 Mach-O, given the recovered references and extra symbols. This is the
writer stage of the native KDK extraction work. `KernelCacheMixer` still calls
the external `ipsw` extractor; reference recovery, symbol synthesis, KDK plist
and pseudo-extension generation are subsequent stages.

The current contract is stripped collections with address-only synthetic binds.
Passing `addressOnlyBinds: false` fails explicitly. Original-symbol C++ alias/PAC
name inference and general shared-cache dylib export are outside this stage.
Nonempty export tries, code signatures, code-signing DRs and linker optimization
hints are rejected rather than preserved with obsolete LINKEDIT offsets.

## Export an image

The internal API takes a decompressed MH_FILESET and an image parsed from it:

```swift
// collection, image, symbols and references come from the extraction layer.
var writer = try KDKImageExport(
    collection: collection,
    image: image,
    baseAddress: baseAddress,
    symbols: symbols,
    references: references,
    addressOnlyBinds: true
)
let standaloneMachO = try writer.export()
```

Use zero as the KEXT base, and the collection's preferred load address for the
kernel. Before exporting `com.apple.kernel`, replace its LC_UNIXTHREAD in place
with the collection's LC_UNIXTHREAD, matching `extract.go`'s
`fixUnixThreadAddress`. This belongs to the caller, not the generic image writer.

Nonempty references select contiguous segment packing. Without references the
writer preserves cache VM addresses while packing file offsets. Input images
and collections stay immutable; repeated exports from the same writer reset
its scratch state and produce the same bytes.

## Reference and evidence

The port follows the MIT-licensed `File.Export` in go-macho PR #94. Its license
is retained in `FirmwarePatcher/KernelCache/KDK/LICENSE`. The external reference
build uses these pinned mpass99 commits, not the released upstream `ipsw`:

| Repository | Commit |
| --- | --- |
| ipsw | `7d81acd4b97e67c0a25b5ddc514ce2ad02e7d474` |
| go-macho | `a8b76580904cdec5a634a9bbc9e8e976d80ddf06` |
| arm64-cgo | `5cac24a3a47df0c29fe6f4ba956dd25b216e54b2` |
| go-dwarf | `bfc1862b701d882faf1cc421f90b960727991e15` |

On 2026-10-23 the writer reproduced **all 264 reference exports byte for byte**:
144 fileset images from `kernelcache.release.vphone600` and 120 from
`kernelcache.release.vresearch101`, including both kernels. The comparison
feeds the identical references/symbols/base/bind mode into Swift and Go. It does
not use the reference output to construct Swift output. This proves the writer
for these inputs; it does not validate the future native reference finder or a
rebuilt collection's boot behavior.

Corpus source: cached cloudOS 26.4 beta IPSW
`c0ecdb4b310cf5239ab2b248dd3098eec297dc5aa3bbe6ad-b80d96a0b616.ipsw`.
The decompressed input hashes are:

| Kernel | SHA-256 |
| --- | --- |
| vphone600 | `681801fe328b00ff8ec2e94a3d84bf9f9a7a1b954640d0c40f8dd02434270935` |
| vresearch101 | `fe345b332fc50586e21707be69accc63e7bc7a855178481a6436727cc24a4e8b` |

The source bytes, captured inputs, and Go exports are external test data. No
Apple firmware, Go runtime, Python, or Homebrew dependency is added to the
shipped bundle. The Go reference is only a development oracle.

## Run the tests

From the repository root, build through the workspace so shared Kit targets are
resolved, using the owning `FirmwarePatcherTests` scheme:

```zsh
xcodebuild -workspace VPhone.xcworkspace -scheme FirmwarePatcherTests \
  -configuration Debug -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath /tmp/native-kdk-build test
```

`KDKExportFixtureTests` creates an entirely synthetic collection. It checks
contiguous layout, restored auth stubs and calls, authenticated binds/rebases,
indirect-symbol fallback, function-start remapping, repeatability, the
cache-address path, and malformed-command rejection. `KDKImageExportTests`
checks all four pointer layouts, signed bind addends, BRAA and OFF12 encodings,
Capstone decoding, and ADRP at high kernel addresses.

BRAA is checked against Apple clang because Keystone 0.9.2 rejects PAC
mnemonics. Independent assembly produced `braa x16, x17 = 0xD71F0A11`,
`braa x0, x1 = 0xD71F0801`, and `braa x30, sp = 0xD71F0BDF`.

The real-corpus test is opt-in. Set `KDK_CORPUS` to an external corpus root with
this layout (the fixture labels are deliberately stable):

```text
data/264beta/kernelcache.release.vphone600.decompressed
data/264beta/kernelcache.release.vresearch101.decompressed
parity/donor/inputs/<entryID>.json
parity/donor/out/<reference-output-path>
parity/research/inputs/<entryID>.json
parity/research/out/<reference-output-path>
```

With `KDK_CORPUS` set in the shell, run:

```zsh
TEST_RUNNER_KDK_PARITY_ROOT="$KDK_CORPUS" \
xcodebuild -workspace VPhone.xcworkspace -scheme FirmwarePatcherTests \
  -configuration Debug -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath /tmp/native-kdk-build \
  -only-testing:FirmwarePatcherTests/KDKImageExportTests \
  -only-testing:FirmwarePatcherTests/KDKExportFixtureTests test
```

Xcode strips the `TEST_RUNNER_` prefix for the test process. To narrow a failure,
set `TEST_RUNNER_KDK_PARITY_ENTRY=com.apple.kernel`; the test then expects two
exports, one per collection. A mismatch reports the first byte offset and saves
`swift-<corpus>-<entryID>` in the corpus root. The default test run skips the
external corpus rather than silently treating absent firmware as success.

The focused validation on 2026-10-23 passed 13 test functions across the KDK
and ARM64 encoder suites, including all 264 external exports. A full scheme run
also executed the new tests successfully but reported 134 issues among 696
tests: existing suites require missing `ipsws/ref_extract` DSC/Mach-O fixtures
and `ipsws/patch_refactor_input` payloads in this new worktree. The main
checkout's DSC directory is empty and the patch-refactor inputs are absent too.
That run is recorded as failed, not as a clean full-suite validation.

The complete `VPhone` scheme build passed, including `Bundle admission passed`.
Local acceptance data is retained under `.build/KDKParity` (ignored by Git),
with focused/full-test and bundle logs in its `validation` directory. Set
`KDK_CORPUS="$PWD/.build/KDKParity"` to replay the corpus from this worktree.

## Rebuild the external reference

Place the four pinned repositories in sibling directories named `ipsw`,
`go-macho`, `arm64-cgo`, and `go-dwarf`, outside this checkout. Apply
[`native_kdk_reference_inputs.diff`](native_kdk_reference_inputs.diff) to the
**external ipsw checkout**. It adds `KDK_DUMP_INPUTS`, which serializes each
`Export` call's entry ID, output path, base, address-only flag, extra symbols and
references before writing the reference binary. It changes no export behavior.

From that external ipsw checkout:

```zsh
cp go.mod go.ref.mod
cp go.sum go.ref.sum
go mod edit -modfile=go.ref.mod -replace github.com/blacktop/go-macho=../go-macho
go mod edit -modfile=go.ref.mod -replace github.com/blacktop/arm64-cgo=../arm64-cgo
go mod edit -modfile=go.ref.mod -replace github.com/blacktop/go-dwarf=../go-dwarf
go build -mod=mod -modfile=go.ref.mod -o ../ipsw-ref ./cmd/ipsw
```

Run `ipsw-ref kernel extract --kdk` for each decompressed collection, adding
`--symbols` followed by the symbol-map filename when one is available,
with `KDK_DUMP_INPUTS` pointing to that corpus's `inputs` directory and the output
root pointing to its `out` directory. Retain any explicit symbols input used
when building the reference corpus; the dump records the resulting writer
inputs, so writer parity does not depend on re-running symbol synthesis.

## Layout invariants

1. Build the segment map, resize `__auth_stubs`, and move later segments before
   copying commands. A containing segment wins over another segment's end;
   section positions move with their own segment to resolve adjacent ranges.
2. Keep the source header's `ncmds` and `sizeofcmds`, adjusting only for explicit
   command additions/removals, as the reference does. Place chained fixups after
   the last segment and split info immediately before function starts.
3. Copy source segment bytes through the collection's address map. Write auth
   stubs, relocate references, reconnect external branches, clear the packed
   `_kmod_info` address/size fields, then restore the FIPS HMAC-SHA256 seal.
4. Reconstruct chained fixups with 4 KiB pages and a four-byte next stride.
   Preserve PAC diversity/address-diversity/key; use low43/high8 for plain
   rebases, 16-bit ordinals and signed19 embedded addends for binds. Import order
   follows sections/atoms, including destructor-pair atom boundaries.
5. Rebuild LINKEDIT in reference order, align blobs to eight bytes, renumber
   symbols and indirect symbols, and truncate the obsolete original tail.
   Symbol records are local/defined/undefined; strings are defined/undefined/local.

## Next integration step

Recover references and synthesize symbols natively, then feed this writer and
reuse the unchanged byte-parity test boundary. Add KDK bundle metadata and KPI
pseudo-extensions before switching `KernelCacheMixer`. Keep `--ipsw` accepted
as a no-op within the existing 2.12 series; removing it requires the planned
2.13 compatibility bump and raised Launchpad `minimumBundleComponents`.

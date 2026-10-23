# Developer disk images on virtual guests

## Implemented HomePod support (2026-10-23)

TempPod (`0000FE01-EEC843C8BD20F085`, HomePod mini 27.2/24K120 over cloudOS
26.4) now mounts Apple's signed tvOS 27B48 cryptex DDI at `/System/Developer`.
CoreDevice reports `connected`, `isCryptexDDI: true`, `contentIsCompatible:
true`, and `isUsable: true`. Process, app, device-detail and crash-log file
queries succeed. Xcode 27.2's Device Hub lists it under Available and shows
DDI Services Enabled, File System Live, and Tunnel State Connected. Its Apps
inspector completes. HomePod has no display, so live preview is unsupported as
expected. DeviceKit's FramebufferProviderStates `none` and preview timeout do
not indicate a DDI failure.
Xcode app installation, launch and LLDB attachment/stack inspection now pass
with the separate persona, signature and research SDK setup described in
`ios27_xcode_persona_lookup.md` and `xcode_install_signature_gate.md`. The UIKit
template's display-backed window scene asserts on HomePod; that limitation is
independent of DDI communication. The headless Foundation test app now runs
under Xcode: source breakpoint, stepping, variable inspection and Objective-C
expression evaluation pass. Other Xcode features remain unverified.

`system-cryptexd-exp-homepod_staging` injects a small TVOS arm64e library
directly into HomePod 27's cryptexd, preserving entitlements and its original
backup. The HomePod preset selects it independently of the iPhone environment.
It implements three scoped compatibility operations:

- Failed class-D `F_SETPROTECTIONCLASS` calls returning `EPERM` report
  `ENOTSUP`, reaching cryptexd's existing unsupported-filesystem fallback.
  Other protection classes, errors and fcntl commands pass through.
- The remote DDI GenericDmg tuple (image-type-index 10, product-class enabled,
  Cryptex1 subtype 2 and nonce domain 4) reads persistence/nonce-persistence
  as zero: Apple's until-reboot mode. Invalid options pass through.
- After the native signature lock succeeds, SEP digest storage still fails
  with `com.apple.security.cryptex.posix` error 104 (`ENOTRECOVERABLE`). Only
  that exact failure is tolerated, and only when the supplied info descriptor
  parses as `com.apple.MobileAsset.DDI`, RequiredMountPath `/System/Developer`,
  and DeveloperModeRequired true. It uses bounded `pread`, retaining the file
  position. Unrelated cryptexes and other failures retain the native result.

The shim retains TSS personalization, Image4 manifest equality, APFS payload
and root-hash authentication, the first native signature lock, and the native
trust-cache/bootstrap path. It specifically omits successful SEP storage for
the until-reboot DDI; it does not provide persistent SEP authorization. The
serial log confirms authenticated mount and a native trust-cache load request;
`dtdeviceinfod` and `dtappserviced` then run from the DDI and answer CoreDevice.
Existing research kernel/TXM policy is unchanged; this is not a claim of stock
hardware security semantics.

### TempPod: staging confirmed, product class revealed

The staging-only build `2.12.0-local.373ae97b` was deployed through Launchpad
to the stopped TempPod clone, UDID `0000FE01-EEC843C8BD20F085`. On boot its
log confirmed the actual `F_SETPROTECTIONCLASS EPERM, reported as ENOTSUP`.
Preparation then returned a concrete APFS mount failure, rather than hanging:
`clas: enforcing[manifest == chip]: 0xf4 == 0xf2`, followed by root-hash
authentication error 13. The staging fix is verified; mounting was still
blocked by the kernel's iOS Cryptex class.

Reveal procedure for `kernelcache.research.vphone600`, cloudOS 26.4 raw
SHA-256 `86895a2eebeb7fcfb68bcd60f2d7e685687faea07ee31166fb58c872b38e0d92`:
the symbol database exists but its referenced JSON dumps are absent. Decode
the kernel with the project's IM4PHandler and Capstone-only KernelPatcherBase.
Find `cryptex1-product-class` string xrefs: uint32 runtime callbacks at file
offsets `0xc78d8c` and `0xc83434`. The CLAS cases read four bytes through
context node pointers at +0x20 and +0x10 respectively, without byte swapping.
Trace the corresponding initializers (`0xc7786c` and `0xc82858`) through
`/product` string xrefs: each stores exactly that node in those fields. The
first getter uses an IORegistry OSData read; the second uses SecureDT. These
are recovered callback roles, not recovered symbol names. No offset is used
by the patch.

`preboot-homepod-exp-cryptex_class` therefore adds the concrete four-byte
`/product/cryptex1-product-class` as native HomePod `0xf4` when absent, or changes
an existing `0xf2` value to `0xf4`. TempPod's restored tree omits it; adding the
property grows the flat tree by 40 bytes. Unexpected values and malformed or
duplicate properties are rejected. All other properties, including product-id,
are preserved. It is composed
from the installer's clean Preboot backup and can be deselected independently.
It retains Image4's equality enforcement, tickets and signatures. The accepted
values are documented in Apple's XNU `EXTERNAL_HEADERS/img4/runtime.h` under
`IMG4_IDENTIFIER_CLAS`; the property path and read layout come from the actual
kernel. The class-only build `2.12.0-local.ce1cc9bf` passed Image4 and APFS
root-hash authentication, mounted `Xcode_tvOS_Cryptex_DDI`, then unmounted after
the SEP storage failure. Thus neither host DDI selection nor TSS needed a bypass.

### SEP reveal and validation

Native HomePod cryptexd SHA-256
`d9de66977d00db02246d237d84e95ccde5cd9407ea71241fdfc4f9ab49210d12`:
Hopper `_sub_remote_service_demux` at `0x100027ff8` reads the two persistence
fields with `xpc_dictionary_get_uint64`; its install block at `0x10002a4fc`
passes the parsed values to the core persistence setters. `_quire_bootstrap_continue`
at `0x100039ce0` calls `cryptex_signature_lock`, then
`cryptex_signature_lock_with_sep(signature, infoFD)` at `0x10003a004`. The second
call is independent of the ephemeral option. REA evidence:
`ev_cd5d8e54bab204df109744019430583894dc3404dde06ff330e4d8242ba6abcf`,
`ev_a760648dda74045963afd7b4dd0b679bcc747e998a156c393ed6df69b18b0076`,
`ev_d1e96c889080feb0eec9ac138b4a6612b02466c67814a6b7b154c461d1878a54`.
The import ABI is corroborated by local disassembly and successful live calls.
No private struct offsets or executable instruction patches are used by the shim.

The installed host has `mountCryptexesEphemerally` in the `com.apple.CoreDevice`
NSUserDefaults suite (not `com.apple.dt.coredevice`). Temporarily enabling it
still failed at SEP storage. Both temporary test keys were removed; no host
preference is required by the guest fix. The guest mapped both fields live in
build `2.12.0-local.d619811f` but likewise failed without the SEP fallback.
Build `2.12.0-local.4cf6da01` then activated the DDI successfully, including
CoreDevice queries and Xcode's ready state above.

Opt-out was tested through `fw set-patches` and Launchpad Update Guest Environment.
It restored cryptexd byte-for-byte to the native SHA-256 above, removed the
library and `.bak`, and restored the complete personalized Preboot IMG4 byte-for-byte
to its saved pre-patch state. The original `homepod-mini` selection (no overrides)
was restored afterward. The full bundle build and admission checks pass; 76
selected patch/catalog/DeviceTree tests and the native arm64 forwarding,
persistence filtering and SEP error-policy harness pass. The native harness
checks unrelated identities, mount paths, absent Developer Mode metadata,
different errors/domains, invalid descriptors, and file-position preservation.

The remaining sections retain the initial Olive investigation as historical
evidence. Olive and the default installed bundle were not modified for this work.

Final deployment: `2.12.0-local.5dc5805b` is installed and bound only to TempPod,
with the original homepod-mini preset and no overrides. After re-enabling the
patches and rebooting, the serial log again confirms fresh authenticated DDI
mount by cryptexd (pid 148), and all four queries below return success:

```sh
xcrun devicectl device info ddiServices --device 0000FE01-EEC843C8BD20F085
xcrun devicectl device info processes --device 0000FE01-EEC843C8BD20F085
xcrun devicectl device info apps --device 0000FE01-EEC843C8BD20F085
xcrun devicectl device info files --device 0000FE01-EEC843C8BD20F085 --domain-type systemCrashLogs --no-recurse
```

Final JSON evidence is `/tmp/temppod-{ddi,processes,apps,files}-final.json`.
Xcode's Apps inspector completes again after this reboot. Both temporary host
preference keys are absent, the read-only inspection disk is detached, and
TempPod is left running. Full VPhone build/admission and the 76 selected Swift
tests passed again on the final implementation.

Investigated 2026-10-23. Host: macOS 27.0.1 (26A434), selected Xcode
`/Applications/Xcode.app/Contents/Developer`, Xcode 27.2 (27B48), CoreDevice
651.31. Live target: Olive, native HomePod mini (`AudioAccessory5,1`, B520AP)
27.2 (24K120) over the cloudOS 26.4 boot chain, VPhone bundle
2.12.0-local.7bd0af87. These are the pre-fix investigation conditions.

## Result

**Olive already passes host DDI selection and TSS personalization.** The host
chooses the public tvOS cryptex DDI, successfully personalizes it, transfers
the assets, and waits inside the remote install operation. The guest has all
the transferred files but stops staging after the first asset. It never
mounts or registers a DDI.

The strongest candidate is the known `cryptexd` protection-class failure
documented in [DeviceHub screen viewing](devicehub_screen_viewing.md).
Olive lacks that workaround because the HomePod preset deliberately excludes
the broad iPhone environment package that carries it. The first experiment
should port the **cryptexd-only staging workaround**, then retry Apple's
ordinary install. There is no evidence that Olive currently needs a TSS
bypass or host identity spoof.

The actual `fcntl` errno has not been captured on Olive. Its staging layout
is strong circumstantial evidence, not proof that the iOS failure is identical.
Later grafting, executable admission and service startup are still untested.

## What was observed live

CoreDevice's device list reports:

| Field | Olive |
| --- | --- |
| Platform / device type | tvOS / homePod |
| Reality | virtual |
| Transport / tunnel | wired / connected, TCP |
| Pairing | paired, manualPairing |
| Developer Mode | enabled |
| Production fused | true |
| Internal OS build | false |
| DDI services | false |

The host already advertises the capability to enable DDI services. USB
enumeration, pairing and the trusted tunnel have therefore progressed far
enough to attempt preparation. `connected (no DDI)` describes a preparation
state; it does not identify which preparation step failed.

Relevant host log sequence, all 2026-10-23 local time (UTC−03:00):

```text
10:52:17.269 Planning to use local DDI from 27B48 at
             /Library/Developer/DeveloperDiskImages/tvOS_DDI
10:52:17.288 Device version 27.2 >= minimum 27.0 for Optional(tvOS).
             Cryptex DDI supported: true
10:52:17.301 Using Cryptex DDI path
10:52:17.307 Device identity: chipID=65025, boardID=144,
             securityDomain=1, productClass=tvOS,
             effectiveProductionStatus=prodFused
10:52:17.308 Resolved cryptex variant name
             'tvOS Customer Developer Disk Image Cryptex'
10:52:18.888 Successfully personalized Cryptex DDI
10:52:18.888 Installing Public Cryptex DDI with ephemeral=false
```

The UUID in these messages matches Olive's CoreDevice record. The TSS request
uses Cryptex1 chip `0xff10`, product class `0xf4`, type 3, subtype 2, nonce
domain 4, the virtual device's UDID and a nonce. There is an actual successful
response, not just a request or an inference from manifest contents.

A one-second `sample` of CoreDeviceService shows its install worker waiting in:

```text
Cryptex.install(onto:options:)
  Cryptex.installRemotely(onto:options:)
    cryptex_remote_service_install2
      -[CryptexRemoteService sendRequestSync:response:]
        xpc_remote_connection_send_message_with_reply_sync
          semaphore_wait_trap
```

Read-only vphoned RPC inspection finds:

```text
/System/Developer                                      empty
/usr/lib/libdevicehubfix.dylib                          absent
/var/mobile/Library/Caches/vphone-devicehubfix.log       absent

/private/var/run/com.apple.security.cryptexd/codex.system/
  remote/frMX0g/
    gdmg   15876608 bytes
    ginf        428 bytes
    gtcd       1763 bytes
    gtgv        229 bytes
    im4m       2977 bytes
  stage/protex.I7DKTq/
    im4m       2977 bytes
```

All six files have the install timestamp, 13:52:18 UTC. The cryptex mount
directory and persistent `codex.system/cryptex` store are empty. Two prior
boot directories retained by `dirs_cleaner` show the same first-asset-only
staging state. `cryptexd` is running without `DYLD_INSERT_LIBRARIES`.
The received `gdmg` size also exactly matches the host's selected cryptex
image, `022-22433-057.dmg`; this is a size comparison, not a content hash.

Later `devicectl device info ddiServices` requests time out while enabling
services. They do not prove a fresh install began: the original remote
install is still outstanding. Prospective guest log streams yielded no new
messages. The installed vphoned has no historical unified-log or stack RPC,
and this guest has no SSH environment; the original errno remains unknown.
As a final read-only recovery, guest Persist/Special trace files, timesync and
UUID text were assembled into a partial local log archive. This decoded 160
cryptexd entries, including the original request and transfer connections,
but no protection-class, copy-asset or staging error. The retained subset
does not establish the errno or rule out errors absent from that subset.

## How the host chooses a DDI

There are three separate choices: platform/variant, compatible developer-tool
contents, and the installation protocol/build identity.

1. **Platform and variant.** Olive reports tvOS, so CoreDevice searches for a
   tvOS DDI and selects the customer/public variant. It does not require an
   `AudioAccessory5,1`-named DDI directory. The observed choice works despite
   `reality=virtual` and the tvOS restore metadata listing Apple TVs rather
   than HomePods.
2. **Host content compatibility.** `version.plist` supplies Platform, Variant,
   ProductBuildVersion and ProjectMetadata. CoreDevice exposes content
   compatibility, usability and its version-check policy. The installed
   iOS/tvOS/watchOS/xrOS DDIs all report build 27B48, CoreDevice 651.31,
   `contentIsCompatible=true` and `isUsable=true` on this host. This selection
   compares developer-tool content; it is not an exact match to the guest's
   firmware build 24K120.
3. **Protocol and identity.** On this tvOS 27.2 guest, CoreDevice explicitly
   chooses its >=27 cryptex path. The expanded BuildManifest identifies
   `tvOS Customer Developer Disk Image Cryptex`. This uses a generic Cryptex1
   identity, rather than the AP board/chip identity of a PersonalizedDMG.

The framework implements `DeveloperDiskImage.bestAvailableDDI`,
`matchingDDIs`, `DDIMetadata.isUsableAndNotOlder` and project-metadata
comparison. Static inspection confirms candidate validation and unusable/old
DDI rejection paths. The complete ranking and tie-breaking algorithm was not
reconstructed; none is needed to establish the actual choice on Olive.

The expanded installed store is `/Library/Developer/DeveloperDiskImages`.
The updater can also consume candidates from the selected Xcode, user-supplied
directories and `/Library/Developer/CoreDevice/CandidateDDIs`. On this host
the latter contains the platform DDI containers. Use the updater rather than
editing the installed root-owned store by hand:

```zsh
xcode-select -p
xcrun devicectl list preferredDDI --verbose
xcrun devicectl help manage ddis update
```

`preferredDDI` without a platform also reports absent macOS/rtKitOS DDIs on
this host. Those warnings are unrelated to Olive's usable tvOS choice.

## Personalized images versus cryptex images

| Route | Selection/signing | Guest operation |
| --- | --- | --- |
| Legacy Developer image | Image plus detached signature | mobile image mounter |
| PersonalizedDMG | AP chip/board/security domain, device identifiers and DDI nonce; AP IM4M | Upload image; MountImage with trust cache and image info |
| Cryptex DDI | Generic Cryptex1 identity, product class, UDID and cryptex nonce; Cryptex1 ticket | Remote cryptex install with image, IM4M, trust cache, info and volume root hash |

The installed iOS manifest does contain AP chip `0xfe01`, board `0x90`,
`ComputeModule14,2` / `vresearch101ap`. It does not follow that every virtual
board can use that AP identity, or that a tvOS PDI has the same coverage.
The generic Cryptex1 identities omit AP chip/board fields: they use chip
`0xff10` and product classes `0xf2` iOS, `0xf3` watchOS, `0xf4` tvOS and
`0xf5` xrOS. Olive's successful ticket demonstrates the practical difference.

Open-source implementations corroborate the protocol split:

- [libimobiledevice's image mounter](https://github.com/libimobiledevice/libimobiledevice/blob/master/tools/ideviceimagemounter.c)
  queries personalization identifiers/nonces, selects an AP build identity,
  requests the ticket, uploads the image and supplies its trust cache.
- [pymobiledevice3's cryptex client](https://github.com/doronz88/pymobiledevice3/blob/master/pymobiledevice3/services/cryptexd.py)
  uses `com.apple.security.cryptexd.remote` over RSD/RemoteXPC and transfers the
  five assets. Its Xcode-compatible request uses image index 10 and nonce
  domain handle 4. That nonce is distinct from the PDI nonce.
- [Its TSS builder](https://github.com/doronz88/pymobiledevice3/blob/master/pymobiledevice3/restore/tss.py)
  constructs the Cryptex1 ticket request. The generic DMG is authenticated
  through the volume root hash; it is not itself an individually personalized
  AP image.

These are protocol references, not proposed runtime dependencies. No Python
was executed or added. Do not extrapolate the host's automatic >=27 policy to
all older releases: direct cryptex tooling has its own version requirements.

## Guest compatibility and the first patch to try

The existing [DeviceHub investigation](devicehub_screen_viewing.md) already
records successful mounting on iOS 27 after this fix:

```c
fcntl(fd, F_SETPROTECTIONCLASS, 4) == -1 && errno == EPERM
    => retain failure return, change errno to ENOTSUP
```

`cryptexd` accepts ENOTSUP as a filesystem without protection-class support.
It treats other failures as fatal. The existing interpose in
`VPhoneGuestComponents/DeviceHubFix/libdevicehubfix.c` changes only that
command/error pair. The prior iPhone failure explicitly named `copy asset:
im4m` and `staging failed`, matching Olive's stranded first asset.

That library currently ships with `system-launchdaemons-boot-environment`.
The HomePod preset blocks it, and `homePodSupportedGuestPatches` excludes it.
Olive's live files and receipt agree. Merely checking a patch box cannot
bypass the installer's supported-platform filter.

Recommended implementation, not yet performed:

1. Capture the original HomePod staging error, or instrument just this
   protection-class operation in a disposable test guest.
2. Extract the staging compatibility into a separately selectable guest patch,
   with a small cryptexd-only TVOS-compatible payload or a semantic executable
   patch. Preserve signing entitlements and support undo/receipt accounting.
   Avoid enabling the complete iPhone launchd environment or the unrelated
   display/GPU portions of DeviceHubFix on HomePod.
3. Admit the declaration in the HomePod patch resolver and preset, mirror the
   shipped/built-in preset changes, and update the binary patch comparison.
   Use the existing supported injection/load-command mechanism; an arbitrary
   launchd environment variable may be stripped for a platform binary.
4. Restart the test guest/connection so the outstanding install cannot hide
   the result. Retry ordinary CoreDevice preparation and observe every stage.

The older personalized-image route has additional known hybrid compatibility
requirements: DiskImages2 ABI/notification-port repairs, mount syscall sandbox
admission, and `diskimagesiod`'s mount-completion gate. See the existing
`KernelCustomFirmwarePatchDiskImages2.swift`,
`KernelCustomFirmwarePatchSandboxExtended.swift` and
`CustomFirmwareDiskImage.swift` implementations and their validation in
`Research/0_binary_patch_comparison.md` (JB-28, JB-09, binary patch 13).
Olive's receipt includes `kernel-boot-di2` and `kernel-boot-sandbox_ext`, but
not `system-diskimagesiod-cfw-is_mount_complete`. Receipt membership alone
does not establish all DI2 subrecords emitted. These are **possible later
or alternate-route requirements**, not the demonstrated current failure.

## What a custom mount must reproduce

Read-only inspection of the installed tvOS cryptex payload finds 15 launchd
jobs. Its cryptex info requires Developer Mode and mount path
`/System/Developer`, with identifier `com.apple.MobileAsset.DDI` and bundle
version 27.2.48.0. Executable paths in its plists are absolute under that
mount point.

| Payload job | Advertised remote service | Purpose |
| --- | --- | --- |
| dtappserviced | com.apple.coredevice.appservice | Apps, processes, launches, executable spawning |
| dtdeviceinfod | com.apple.coredevice.deviceinfo | Extended device and DDI information |
| dtdebugproxyd | com.apple.coredevice.debugserverproxy | Debugger connection |
| testmanagerd | com.apple.dt.testmanagerd.remote | XCTest |
| dtfileserviced | com.apple.coredevice.fileservice.control/data | File operations |
| dtremotedisplayd | com.apple.coredevice.displayservice | Screen streaming |

The first three services require the host client's respective
`canInstallCustomerContent`, `canRetrieveDeviceInfo` and
`canDebugApplicationsOnDevice` CoreDevice entitlements and use RemoteXPC.
The testmanager service uses a different transport declaration and requires
`com.apple.private.dt.testmanagerd.client`. Root privileges in the guest alone
do not replace these protocol/service relationships.

A TSS-free prototype would need to:

1. Attach/graft compatible DDI contents at the required path, accounting for
   the hybrid kernel's filesystem/driver interfaces.
2. Admit the executables and frameworks (trust cache or another working guest
   code-signing path), preserving entitlements/platform identity needed by
   debugserver and other privileged services.
3. Activate the launchd jobs, publish their RemoteServices through remoted,
   and provide the DDI metadata and notifications CoreDevice expects.
4. Demonstrate that the host accepts that state, discovers the services and
   completes the intended operations after reconnect and reboot.

Neither copying files into `/System/Developer` nor changing a host DDI-ready
flag proves these requirements. Ordinary `launchctl bootstrap` may help with
step 3, but whether it reproduces native cryptex activation completely has
not been tested. A signature-verification bypass must be located at an actual
failing check; there is no established universal one-instruction DDI bypass.
On Olive, retaining the already successful ticket path eliminates much of
this custom registration work.

## Validation and remaining limits

The next implementation is successful only when all relevant layers pass:

1. Guest staging finishes, a cryptex is persisted/registered, and the DDI
   contents are accessible at `/System/Developer`.
2. `devicectl device info ddiServices` returns current metadata; the device
   reports DDI services available and gains the payload's capabilities.
3. Device details, process listing and file operations complete through
   CoreDevice. Launch and attach to a compatible test executable and verify
   a breakpoint/continue cycle. Test XCTest separately if required.
4. Repeat after reboot and reconnect; verify no stalled original install or
   cached device record is supplying a false positive.

Mounting enables services, not every Xcode feature on every product. HomePod
is classified as homePod/tvOS, and Xcode's target/product support still
applies. The iPhone persona-lookup and DeviceHub policy fixes documented
elsewhere are separate from DDI installation. Device-support symbol
extraction also needs valid shared-cache page hashes after cache patching;
the existing maxSlide research records a mounted/usable device still taking
minutes to debug when extraction silently failed. Do not report a successful
app install as proof of debugging, XCTest or screen streaming.

Answered: Olive's selected image/variant, successful personalization,
transferred assets, current stop layer, missing existing compatibility fix,
payload service requirements, and a concrete first implementation path.
Unresolved: Olive's exact staging errno, completion after that repair,
individual HomePod developer features, and a fully working TSS-free mount.

## Evidence and reproduction

Read-only host/device commands and one normal DDI-preparation request were
used. No guest patch, preset, host security setting or device identity was
changed. Owned read-only DDI mounts were detached. CoreDevice REA sessions
were closed. The normal preparation request remained pending on the host
after the CLI timeout; no daemon was killed to clear it.

Local scratch evidence from this investigation:

- `/tmp/vphone-ddi-devices.json`: device snapshot (includes other devices;
  avoid publishing it wholesale).
- `/tmp/vphone-ddi-preferred.json`: preferred platform DDIs.
- `/tmp/vphone-ddi-host.log`: host selection/TSS/install timeline; contains
  ticket material, so this report retains only relevant excerpts.
- `/tmp/vphone-ddi-coredevice.sample.txt`: stack sample showing remote wait.
- `/tmp/vphone-ddi-olive-mount.json`: explicit request timeout.
- `/tmp/vphone-guest-ddi-findings.md`: read-only RPC observation ledger.
- `/tmp/olive-ddi-cryptexd-history.log`: recovered historical cryptexd entries
  from the partial archive at `/tmp/olive-ddi.logarchive`.
- `/tmp/vphone-ddi-protocol-evidence/tvos-ddi-plists.json`: payload job and
  version metadata inventory.

REA/Hopper identified CoreDevice SHA-256
`00bf7055ace3517b0e4c03b12a462eeabed02a17da0b0cc4951e3bd3e56eb48a`
and CoreDeviceService SHA-256
`a145f8a1500a38dbe034152efd0654982c1cd04744880ae0de145018425318ab`.
Framework procedure inventory evidence:
`ev_9058d198e572ac8904a2ad449cb676de67062de74ec490712b0b5060e549d8a2`;
candidate-selection pseudocode:
`ev_b13dc4b37d833b85dcdaccf545f0c01869c83dc115f59912c0039ab1d15baaaa`;
metadata ordering pseudocode:
`ev_25df22cb149029957eb22e1611fb9972e465ed7824e1783f8b87c00a32252ebd`;
service protocol-path pseudocode:
`ev_b92b52e8f2a9478bf1545a61d3a195ceaa881389264a7759fc05f5598bf7c7b9`.
These are static observations; the host logs and sample separately establish
the executed path. Hopper's Swift pseudocode has substantial recovery noise;
no exact ranking or unsupported code path is claimed from it.

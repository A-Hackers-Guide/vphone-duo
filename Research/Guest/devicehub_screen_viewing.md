# DeviceHub screen viewing

Xcode 27 ships `DeviceHub.app` (`Xcode.app/Contents/Applications`, bundle id
`com.apple.dt.Devices`). It lists vphone guests as "iPad / iPhone — Virtual
Machine" and, for a paired guest with its developer disk image (DDI) mounted,
opens a live view of the screen. Before this work the view spun forever on
every guest, 26.x and 27.x alike.

Measured with Xcode 27.0 (27A266a) and CoreDevice 642.16 on macOS 27.0.1,
against `iPad16,1 26.6.2 (23G90)` and `iPhone17,3 27.0.1 (24A446)` guests
over cloudOS 26.4, 2026-10-06 and 2026-10-07.

Status: the live view works on both versions. Latency that grows over a long
session, and occasional multi-second stalls after a cold start, are open (see
[Open](#open)).

## What stopped it

Each version stopped at a different place, and a 27.x iPhone stopped at all
four:

| Stage | Symptom | Affects | Fixed by |
| --- | --- | --- | --- |
| DDI mount | "connected (no DDI)" for good | 27.x | `cryptexd` hook |
| Feature query | `supportedFeatures: 0`, view spins | every guest | `dtremotedisplayd` hook |
| Capture display | stream starts, view stays black | 27.x | conditional IOMFB dispatch |
| Display metadata | screen drawn over the bezel corners | 27.x iPhone | `dtdeviceinfod` hook |

### iOS 27: the DDI does not mount

CoreDevice personalizes the cryptex DDI (TSS succeeds) and hands it to the
guest, then nothing more happens. The device stays "connected (no DDI)" and
DeviceHub logs `No providers can handle Display ID: 1 … (bootState: Booted,
ddi: false)`. The guest's `cryptexd` says why:

```text
[protex] set protection class: [1: Operation not permitted]
[protex] copy asset: im4m: [1: Operation not permitted]
[protex] copy assets failed: [1: Operation not permitted]
[codex] system: staging failed [1: Operation not permitted]
```

In `__protex_stage_continue` (`/usr/libexec/cryptexd`, 27.0.1) each staged
asset is opened `O_RDWR` and given class D with
`fcntl(fd, F_SETPROTECTIONCLASS, 4)`. A failure other than `ENOTSUP` (45)
aborts staging, and the guest returns `EPERM`. iOS 26 guests mount the DDI
without this.

### Every guest: no media stream features

DeviceHub asks the device for its media stream features before it starts a
stream (`MediaStreamGetSupportInfoActionDeclaration`, forwarded to the device
feature `com.apple.coredevice.feature.getmediasupportinfo`) and repeats the
question with backoff (1 s, 2 s, 4 s … 30 s) until the answer is non-empty. A
guest answers every time with

```text
SupportInfo: supportedFeatures: 0 (No supported features are available:  (Raw Value: 0),
    avcFrameworkVersion: Optional("2215.5.1"), coreDeviceVersion: nil)
```

and DeviceHub logs `No framebuffer provider found for Display ID: 1 —
creators tried: [… AVConferenceDisplayViewFramebufferProviderCreator=
canProvideView:false …]`. The Mac reports its own features as
`Primary video display mirrored output stream, System audio output stream,
Display information (Raw Value: 140)`.

The answer comes from the DDI's `dtremotedisplayd`
(`/System/Developer/usr/libexec/dtremotedisplayd`, LaunchDaemon
`com.apple.coredevice.dtremotedisplayd`, user `mobile`). Its remote service
`com.apple.coredevice.displayservice` carries `getmediasupportinfo`,
`getmediastreamserverstatus`, `startaudiooutput`, `startvideooutput`,
`startmediastream` and `stopmediastream`. It returns
`MediaStreamSupportedFeatures.current` from the DDI's
`CoreDeviceUtilities.framework`
(`$s19CoreDeviceUtilities28MediaStreamSupportedFeaturesV7currentACvgZ`).

`current` builds a `CurrentDevice` and calls
`forDeviceInfo(osBuildUpdate:platform:deviceType:isVirtualDevice:mode:isProductionFused:hasInternalOSBuild:hasInternalDDI:)`.
Its log strings name the policies, and none of them is a capability check:

- `Remote control restricted. Device is customer-restricted (production
  fused, customer OS, customer DDI) and running pre-27.0 OS`. The predicate
  `CurrentDevice.isCustomerRestricted(isProductionFused:hasInternalOSBuild:hasInternalDDI:)`
  disassembles to `isProductionFused && !hasInternalOSBuild &&
  hasInternalDDI == false`. Every 26.x guest is refused here.
- `Remote control is only available on iOS 27.0, watchOS 27.0, or tvOS 27.0
  or later.`, shown when the device is not an iPhone, Apple Watch or Apple TV.
  Every iPad guest is refused here, whatever its version.
- A per-build table (`MediaStreamSupportedFeatures.MinimumVersions`) keyed by
  build, platform and device type, which also takes `isVirtualDevice`.

The guest does not persist the info-level `inputs:` line, and the hook replaces
the answer on every version, so the branch a 27.x iPhone would take on its own
was not observed. `current` also returns no features when `CurrentDevice.init`
cannot build the device identity (version number, build update, device type);
there is no compositor-readiness gate in it.

Feature bits (`MediaStreamSupportedFeatures` static getters):

| Bit | Meaning |
| --- | --- |
| `0x4` | primary display mirrored output (screen sharing) |
| `0x8` | system audio output |
| `0x40` | virtual external / secondary virtual display output |
| `0x80` | display information |
| `0x100` | video output by display ID |
| `0x200` | screenshot capture |

`devicectl device capture screen-record` is a separate feature
(`com.apple.coredevice.feature.screenrecording`) that a guest does not list,
so it is no way around this.

### iOS 27: the capture display is black

With the DDI mounted and features reported, a 27.0.1 stream starts but shows
black, and the guest's `FigVirtualDisplayProcessor` reports `Submits 0 /
Encodes 0`. backboardd logs, about fifty times a second:

```text
[WindowServer] display 2 get_wireless_surface_options returned error e00002d5 / e00002be
[WindowServer] display 2 swap_end returned error 10000003
```

Display 2 is the capture display the stream adds. `10000003` is
`MACH_SEND_INVALID_DEST`.

The cause is the iOS 27 force-kern patch (row 11 of the guest DSC table in
`Research/0_binary_patch_comparison.md`). iOS 27 presents the paravirtual
main display through IOMobileFramebuffer's in-process `_virt_Swap*` path,
which never reaches the 26.4 kernel's paravirtual GPU. The patch therefore
sent every public `_IOMobileFramebufferSwap*` call to `_kern_Swap*`, which
calls the kernel userclient. The capture display, however, is a genuine
virtual display: it has no userclient port, so its kernel swaps fail, and its
frames never reach the in-process consumer that `_virt_SwapEnd` hands surfaces
to. `get_wireless_surface_options` then has nothing to return
(`e00002be` is `kIOReturnNoResources`, `e00002d5` `kIOReturnBusy`).

Every `_kern_Swap*` implementation loads the connection's IOConnect port from
`[x0, #0x14]`. That port is non-zero for the paravirtual main display and zero
for the capture display.

### iOS 27 iPhone: no framebuffer mask

DeviceHub draws the screen inside a device chrome and clips it with a
framebuffer mask. The DDI's `dtdeviceinfod` (not `dtremotedisplayd`)
implements the DisplayInfo and DisplayInfoUpdates actions. It reads
`MGCopyAnswer("DisplayExtendedProperties")` and otherwise falls back to
`ChromeIdentifier` and `FramebufferIdentifier`. On the 27.0.1 guest these
answer `null`, `com.apple.dt.devicekit.chrome.phone11` and `null`. With a
chrome but no mask, DeviceKit falls back to a rounded rectangle and the
content runs over the bezel corners.

`/Library/Developer/DeviceKit/chrome_map.plist` maps `iPhone17,1` to `phone11`
with mask `4E5532ED-1470-47D1-BDF4-7AA90C26957A` (and `iPhone17,3` to
`phone9` with `A6AC96E7-…`). It has no entry for the guest's `iPhone99,11`.
`DeviceTreeGuestDevicePatches` deliberately keeps the virtual
`framebuffer-identifier` while copying the real board's chrome properties, so
the device tree is not the place to fix this. Matching the guest's resolution
to an iPhone 16 (1179x2556) did not change the overflow either.

## The fix

### `libdevicehubfix.dylib`

`VPhoneGuestComponents/DeviceHubFix/libdevicehubfix.c`, installed as
`/usr/lib/libdevicehubfix.dylib`. Both spawn hooks insert it into three
processes only (`vpIsDeviceHubFixTarget` in `Shared/InjectionEnvironment.h`):

- **`cryptexd`**: interposes `fcntl`. An `EPERM` from `F_SETPROTECTIONCLASS`
  is reported as `ENOTSUP`, which takes the path `cryptexd` already has for a
  filesystem without protection classes. Every other call and failure is
  untouched.
- **`dtremotedisplayd`**: interposes `MediaStreamSupportedFeatures.current`,
  which answers `0x8c` (what a Mac host reports for itself; the host
  intersects it with its own), and `CurrentDevice.isCustomerRestricted`, which
  answers false. The struct is resilient (the framework is built for library
  evolution), so the getter returns it indirectly through `x8`; the
  replacement is three instructions of assembly.
- **`dtdeviceinfod`**: interposes `MGCopyAnswer`. Only when
  `FramebufferIdentifier` is missing and `ChromeIdentifier` is exactly
  `phone11`, it answers with Xcode's matching mask `4E5532ED-…`, retained under
  the Copy ownership rule. Existing answers and other chromes are unchanged.
  This is display metadata, not a change to the guest's hardware identity.

Interposing works because `cryptexd`, `dtremotedisplayd`, `dtdeviceinfod` and
`CoreDeviceUtilities` are standalone images, not shared-cache ones, so dyld
binds their imports through the interposing table. `CoreDeviceUtilities` lives
on the DDI and not in the SDK, so its two symbols are weak flat-namespace
imports (`-Wl,-U`) and resolve to nothing in `cryptexd`.

The library ships with `system-launchdaemons-boot-environment`. An existing
guest gets it from the environment update when it next starts on a bundle
that has it.

### Conditional IOMFB dispatch

`DyldSharedCacheIOMFBForceKernPatcher` now rewrites each public swap
trampoline as:

```text
cbz   x0, <original failure>
ldr   w16, [x0, #0x14]       ; IOConnect port, zero for the capture display
cbnz  w16, _kern_Swap<Name>
b     _virt_Swap<Name>
```

`x16` is an intra-procedure-call scratch register, so the arguments reach
either implementation intact. The public, `_kern_` and `_virt_` siblings are
resolved by name; only operations with all three take part, and `SwapBegin`,
`SwapEnd` and `SwapSetLayer` must be covered. Capstone checks the trampoline
shape and the port load's operands, `ARM64Encoder` produces all four words
(`encodeCompareBranch` is new, pinned against keystone), and the 16-byte write
spans are re-attested. On 24A446 it rewrites ten entry points and leaves
`SwapSignal`, which is not a thin trampoline, on its existing path. The
`0x14` port offset was verified on 24A446 only.

### Upgrading an existing iOS 27 guest

Nothing to do by hand: bind the machine to the new bundle with its guest
environment (Launchpad's bundle switch, or `vm set-bundle <vm> <version>
--update-environment`), or run `cfw install` / `cfw update-environment`.

The patch identifier did not change, and `applyDyldPatches` normally skips an
enabled patch whose identifier is already in the guest receipt, which would
leave the old 31 four-byte sites in place for good. The undo log tells the two
implementations apart: the old one recorded 4 bytes per entry point, the new
one 16. `DyldSharedCacheUndoLog.outdatedImplementations` names that shape, and
for such a patch the installer reverts its records and applies the current
implementation in the same run. A second run finds 16-byte records and leaves
the cache alone. If the revert succeeds and the new write fails, the patch is
reported as failed and left out of the receipt rather than listed as applied.

A guest patched before the undo log existed has no records, so it cannot be
reverted this way and keeps the old bytes; it needs a restore.

**Validated (2026-10-07, `iPhone17,3 27.0.1`):** the guest was put back on the
old implementation with bundle 2.6.0 (`31 newly forced`), then bound to the new
bundle with `--update-environment`. The log shows `an earlier implementation is
applied; reverting it and applying the current one`, 31 four-byte reverts and
`10 newly forced, 0 already conditional`. A further `cfw update-environment`
did not touch the patch. After boot the VZ window scanned out and DeviceHub
showed the guest live, 30–40 ms behind the VZ window.

## Validation

- **`iPad16,1 26.6.2 (23G90)`, new test VM.** DeviceHub receives
  `supportedFeatures: 140`, `MediaStreamStart` succeeds for audio and video,
  and the view shows the live home screen, also after a cold start on the
  built bundle. SystemHook logs `inserted+devicehubfix` for `cryptexd` and
  `dtremotedisplayd`. `cryptexd` never takes the `EPERM` path on 26.x. An
  unpatched 26.6.2 iPad kept answering 0 throughout.
- **`iPhone17,3 27.0.1 (24A446)`, new test VM.** Without the hook the DDI
  never mounts. With it the hook logs `F_SETPROTECTIONCLASS EPERM, reported as
  ENOTSUP` once and the device becomes `connected` with DDI services.
  - With the old patch the stream starts but stays black (above).
  - After reverting and reapplying with the conditional dispatch, the VZ
    window still scans out, the guest encodes 41–60 fps, and DeviceHub shows
    the home screen and Settings live.
  - With the mask, DeviceHub logs `Found FramebufferMaskIdentifier from
    displayInfo` with the `phone11` UUID, and the home screen and Settings are
    clipped inside the chrome at all four corners.
  - A swipe sent to the guest moved the Settings list identically in the VZ
    window and in DeviceHub.
- **Tests.** `InjectionEnvironmentTests` covers the three targets and their
  near-miss suffixes. The real-cache force-kern tests cover conditional
  routing, the preserved null check, symbol discovery, dry run and
  idempotence. `ARM64CompareBranchTests` pins the new encoder.

Touch input sent from inside DeviceHub reaches the guest (checked by hand),
but has no automated check.

## Open

### Latency grows over a long session

Measured on the 26.6.2 iPad from a guest screen change (an `apps.launch` RPC)
to the first changed DeviceHub frame; the VM's own window takes about 0.4 s
for the same change:

| Stream age | DeviceHub |
| --- | --- |
| new | 0.48 s |
| about 12 min | 0.55–0.59 s, rising in steps |
| about 50 min | 2.6 s |

Recreating the stream (killing the guest's `avconferenced`) resets it.

Ruled out:

- **Mac receiver.** For the whole session the video jitter queue stays at
  100 ms (briefly up to 500 ms), one frame is pending, and the playback offset
  is constant. The image queue displays about 25 ms after enqueue. DeviceHub
  and `avconferenced` use a few percent CPU.
- **Guest encoder and transport.** HEVC encoding takes about 5 ms a frame,
  RTT is 2 ms, the one-way delay estimate 9 ms, with no loss.
- **The audio stream.** The audio path is unhealthy (erasures, late packets,
  an audio jitter queue that reached 11.76 s before it was discarded), but a
  video-only stream (features `0x84`) grew at the same rate.
- **Clock drift.** The guest's monotonic clock runs within 3 ppm of the host's.

So the frames already carry late timestamps when they reach the Mac. The
likely place is the guest's mirroring into the capture display, ahead of the
encoder (backboardd to `FigVirtualDisplayProcessor`). Confirming it needs
per-frame timing inside the guest; the logs are too coarse.

### Stalls after a cold start

Separately, on the 27.0.1 iPhone, DeviceHub sometimes stuttered for a few
seconds right after a cold start while the VZ window stayed fluid. In the one
confirmed case the Mac's HEVC decoder received nothing for about five seconds
while the receiver still counted packets. DeviceHub then sent a FIR with
reason `No video displayed timeout fail safe` and recovered. In another cold
start, while the guest was still booting, the guest's encoder and
`FigVirtualDisplayProcessor` reports stopped for about 17 seconds while
transport health messages continued. On recovery, 22 `VTP_Send` calls failed
with `ENOBUFS` and one encode took 125 ms, which looks like a consequence of
the burst rather than its cause. Nine other cold starts were healthy (newest
presentation under 25 ms old), and a run under the same test load as the
failure peaked at 240 ms. This also points at the guest's capture or encode
path.

`alarmsSentForDecodeButNotDisplayedCount=16` stays at its threshold even
after presentation recovers, so that warning is no failure detector.

### Other

- iPad guests on 27.x were not tested.
- The `0x14` port offset in the conditional dispatch is fixed, not derived;
  check it on the next 27.x build.

## Measuring

- **Open a guest in DeviceHub without clicking:** `open
  "devices://device/open?id=<CoreDevice identifier>"`, using `identifier` from
  `xcrun devicectl list devices --json-output -` (not the UDID). It opens or
  raises a viewer window and starts the stream.
- **DeviceHub's windows are not in the accessibility tree.** Capture them
  with `screencapture -x -o -l <CGWindowID>`, the ID from
  `CGWindowListCopyWindowInfo` filtered by DeviceHub's pid.
- **Latency:** take a base frame, change the guest screen through vphoned, and
  capture repeatedly until the centre of the frame differs; repeat on the VM
  window for the baseline. A guest app that draws the guest's epoch
  milliseconds at 60 Hz allows paired VZ/DeviceHub screenshots instead; a
  common host/guest offset is not DeviceHub latency.
- **Host logs:** `/usr/bin/log show` (zsh shadows `log`). In DeviceHub,
  `MediaStreamGetSupportInfo` and `MediaStreamStart` replies. In the Mac's
  `avconferenced`, `Health: VideoReceiver` (`videoJitterQueueSize`),
  `Health: VCVideoPlayer` (presentation times) and `VCPDec` (decoder input).
  Player addresses are reused across streams, so start a stream's series at
  its `displayLinkTickCount=0` line rather than matching the pointer.
- **Guest logs:** vphoned `logs.syslog` takes `level` `all`, `error` or
  `fault`; info lines are not persisted. `avconferenced` prints
  `fvdp_statsReport`, `VCPEnc` and `Health: VideoTransmitter` every second.
- **Guest profiling:** follow `Research/Guest/display_refresh_rate.md` and
  never sample the host VM process at the same time. A targeted capture is
  enough: `spindump avconferenced 40 20 -onlyTarget -wait -noBinary -file
  <report>`.
- **Restarting the stream:** `processes.kill` sends `SIGTERM` by default,
  which `dtremotedisplayd` ignores; pass `"signal": "KILL"`. The stream
  itself lives in `avconferenced`.
- **Screenshots are no evidence of scanout.** vphoned's `screen.screenshot`
  and the control socket's `screenshot` read the guest, and DeviceHub's saved
  screenshot showed the home screen while its live panel was black. Look at
  the VZ window and DeviceHub's live panel directly.

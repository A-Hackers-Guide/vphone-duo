# DeviceHub screen viewing

Xcode 27 ships `DeviceHub.app` (`Xcode.app/Contents/Applications`, bundle id
`com.apple.dt.Devices`). It lists vphone guests as "iPad / iPhone — Virtual
Machine" and, for a paired guest with its developer disk image mounted, opens
a live view of the screen. Before the fix the view spun forever for every
guest, 26.x and 27.x alike, and a second window reported "Connection timed
out". The two versions stop at different places: a 27.x guest never mounts
the DDI, and a 26.x guest mounts it and then reports no media stream
features.

Measured with Xcode 27.0 (27A266a), CoreDevice 642.16, on `iPad16,1 26.6.2
(23G90)` and `iPhone17,3 27.0.1 (24A446)` guests over cloudOS 26.4.

## iOS 27: the DDI does not mount

CoreDevice personalizes the cryptex DDI (TSS succeeds) and hands it to the
guest, then nothing more happens; the device stays "connected (no DDI)" and
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
`fcntl(fd, F_SETPROTECTIONCLASS, 4)`; a failure other than `ENOTSUP` (45)
aborts staging. The guest returns `EPERM`. `cryptexd` already treats
`ENOTSUP` as a filesystem without protection classes, so the hook reports
this one `EPERM` as `ENOTSUP`. iOS 26 guests mount the DDI without it.

## Where a mounted guest stops

DeviceHub asks the device for its media stream features before it starts a
stream (`MediaStreamGetSupportInfoActionDeclaration`, forwarded to the device
feature `com.apple.coredevice.feature.getmediasupportinfo`). It repeats the
question with backoff (1 s, 2 s, 4 s … 30 s) until the answer is non-empty.
A guest answers every time with

```text
SupportInfo: supportedFeatures: 0 (No supported features are available:  (Raw Value: 0),
    avcFrameworkVersion: Optional("2215.5.1"), coreDeviceVersion: nil)
```

and DeviceHub logs `No framebuffer provider found for Display ID: 1 —
creators tried: [… AVConferenceDisplayViewFramebufferProviderCreator=
canProvideView:false …]`. The Mac side's own features are fine
(`found supported features: Primary video display mirrored output stream,
System audio output stream, Display information (Raw Value: 140)`).

`devicectl device capture screen-record` is a separate feature
(`com.apple.coredevice.feature.screenrecording`) that a guest does not list,
so it is not a way around this.

## The device side

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
Its log strings name the policies; none of them is a capability check:

- `Remote control restricted. Device is customer-restricted (production
  fused, customer OS, customer DDI) and running pre-27.0 OS (major: …).
  Returning no supported features.` The predicate
  `CurrentDevice.isCustomerRestricted(isProductionFused:hasInternalOSBuild:hasInternalDDI:)`
  disassembles to `isProductionFused && !hasInternalOSBuild &&
  hasInternalDDI == false`. Every 26.x guest is refused here.
- `Remote control is only available on iOS 27.0, watchOS 27.0, or tvOS 27.0
  or later.` — shown when the device is not an iPhone, Apple Watch or Apple
  TV. Every iPad guest is refused here whatever its version.
- a per-build table (`MediaStreamSupportedFeatures.MinimumVersions`) keyed by
  build, platform and device type, which also takes `isVirtualDevice`.

The guest does not persist the info-level `inputs:` line, and the hook
replaces the answer on every version, so the branch a 27.x iPhone guest
would take on its own was not observed.

Feature bits (`MediaStreamSupportedFeatures` static getters):

| Bit | Meaning |
| --- | --- |
| `0x4` | primary display mirrored output (screen sharing) |
| `0x8` | system audio output |
| `0x40` | virtual external / secondary virtual display output |
| `0x80` | display information |
| `0x100` | video output by display ID |
| `0x200` | screenshot capture |

## The fix

`VPhoneGuestComponents/DeviceHubFix/libdevicehubfix.c`, installed as
`/usr/lib/libdevicehubfix.dylib`, is inserted by both spawn hooks into
`cryptexd` and `dtremotedisplayd` only (`vpIsDeviceHubFixTarget` in
`Shared/InjectionEnvironment.h`). In `cryptexd` it interposes `fcntl` as
above. In `dtremotedisplayd` it interposes two getters:

- `MediaStreamSupportedFeatures.current` answers `0x8c`, the features a Mac
  host reports for itself. The struct is resilient (the framework is built
  for library evolution), so the getter returns it indirectly through `x8`;
  the replacement is three instructions of assembly. The host intersects the
  answer with its own features.
- `CurrentDevice.isCustomerRestricted` answers false.

Interposing works because both `dtremotedisplayd` and `CoreDeviceUtilities`
are DDI images, not shared-cache ones, so dyld binds their imports through the
interposing table. The imports are weak flat-namespace symbols (`-Wl,-U`),
because neither image is in the SDK.

The stream itself is AVConference screen capture inside the guest. It needs
nothing else: once the answer is non-empty DeviceHub's
`MediaStreamStartActionDeclaration` succeeds for audio and video and the view
shows the live screen.

## Validation

**`dhtest-ipad`, `iPad16,1 26.6.2 (23G90)` (2026-10-06):** prototype pushed
through the environment update (built in the `libbatteryhealthfix.dylib` slot,
with a SystemHook that inserted that slot into `dtremotedisplayd`). The hook's
log showed `features=0x8c current=interposed isCustomerRestricted=interposed`.
DeviceHub then received `supportedFeatures: 140 (Primary video display
mirrored output stream, System audio output stream, Display information)`,
`MediaStreamStart` returned success, and the window opened with
`devices://device/open?id=<CoreDevice identifier>` showed the guest's home
screen live. The user's own 26.6.2 iPad, without the hook, kept answering 0
throughout.

The same day, on the built bundle (`2.6.1-local`, bound with `vm set-bundle
--update-environment`): after a cold start SystemHook logged
`dtremotedisplayd decision=inserted+devicehubfix` and the view came up again.

**`dhtest-iphone27`, `iPhone17,3 27.0.1 (24A446)` (2026-10-06):** without the
hook the DDI never mounted (above). With it `cryptexd` logged
`F_SETPROTECTIONCLASS EPERM, reported as ENOTSUP` once, CoreDevice showed the
device as `connected` with DDI services, DeviceHub received 140 and
`MediaStreamStart` succeeded — and the view stayed black while the guest's own
screen was on and unlocked.

## Open: a black view on iOS 27

During the 27.0.1 stream backboardd logs, about fifty times a second,

```text
[WindowServer] display 2 get_wireless_surface_options returned error e00002d5 / e00002be
[WindowServer] display 2 swap_end returned error 10000003
```

Display 2 is the capture display the stream adds; the 26.6.2 iPad logs none of
this while streaming. The frames die in the IOMobileFramebuffer swap path for
that display, the same layer rows 9 and 11 of
`Research/0_binary_patch_comparison.md` patch for the main display
(`_kern_SwapEnd`, the `_IOMobileFramebufferSwap*` trampolines). That is where
the next step starts. A `locationd` crash (`EXC_ARM_PAC_FAIL`) on the same
guest predates the hook and does not involve it.

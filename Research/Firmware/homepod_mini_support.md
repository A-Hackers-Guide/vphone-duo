# HomePod mini virtualization

HomePod mini is a separate guest family, `homePod`, using the TVOS executable
platform and monolithic filesystem. It is not an Apple TV: it has its own
IPSW, accessory identity and services, and does not use TV remote navigation,
the Apple TV HD restore base, or the Apple TV 4K OTA userland replacement.

## Firmware evidence

Inspected on 2026-10-22 from the supplied
`AudioAccessory5,1_27.0_24J361_Restore.ipsw`:

- HomePod Software 27.0, build 24J361; `AudioAccessory5,1`, `b520ap`, CPID
  `0x8006`, BDID `0x22`, SDK platform `appletvos`.
- File length 4,297,178,355 bytes. Apple's CDN declares SHA-256
  `6ae3add6733be34e15924b7710cfc5e0dc97425687ab8cac38e8466add9b4ae3`.
- Native OS image `043-04683-522.dmg.aea`; no OS/App cryptexes. The cache is
  `System/Library/Caches/com.apple.dyld/dyld_shared_cache_arm64e`.
- `/usr/lib/dyld` and `/sbin/launchd` are arm64e, TVOS 27.0. dyld UUID
  `4DB71CBA-9E39-3329-A28A-D34327983DCD`, SHA-256
  `50edaf559476cd21faa30cec1a0e35e602cf6f3737dbb119d2c2b2441e0d871f`.
  REA native inspection evidence:
  `ev_8551f4aa79ea0b1e08633431becb115a4f44cfd102f7c31e58d70cd42a135c8a`.
- The B520 tree reports `model=AudioAccessory5,1`, `compatible` beginning
  `B520AP`, `horseman=1`, concrete empty `siri-hub`, and
  `app-macho-architecture=arm64`. That last capability describes app admission;
  it does not mean the OS cache is plain arm64. Artwork values describe no
  panel: idiom `0`, subtype 0, scale 0.
- Userland includes `HPSetup.app`, AirMusic, AirPodcasts and backboardd.

The firmware catalog points to the [Apple-hosted IPSW](https://updates.cdn-apple.com/2026SFallFCS/a595a3b2-2c42-470a-9417-a705aaafa05c/AudioAccessory5,1_27.0_24J361_Restore.ipsw).
The boot chain, kernel and SEP remain cloudOS 26.4 beta (23E5207q), with
OpenAVB/OpenSEP as for other new machines.

## Implementation

`usesTVOS` shares platform-dependent daemon selection, monolithic layout
admission, hybrid SHA-384 component authentication, cache paths, and guest-patch
validation. Apple TV-specific menus and OTA replacement still use the Apple TV
family. The HomePod mini uses the existing TVOS-retargeted vphoned executable.

`homepod-mini` selects the existing 27 userland/kernel compatibility patches
and vphoned. GPU injection, iPhone audio/camera/sensor/environment hooks,
Apple TV OTA replacement and plain-arm64 TPRO workarounds stay off. The shared
virtio-snd driver selects B520 routing through VirtualAudio's audio-only
`ProductIDOverride = 4`; the global VM product token stays unchanged. The donor
token repair is blocked by default, including on HomePod. The existing Preboot
inverse restores this VM's original token during an environment update. The
[audio routing and live findings](../Guest/homepod_audio.md) track the remaining
output work. Physical accessory transports require separate validation.

The new `devicetree-cfw-homepod_product` declaration copies `horseman`,
`siri-hub` and app architecture from the actual donor tree, only for B520's
installed identity. It uses parsed property flags; a syscfg placeholder is
removed rather than copied as data. Existing board presentation supplies the
model/product strings, removes phone-only capabilities and retains virtual
hardware nodes. The restore tree retains the research identity.

HomePod has no display panel. The 320×320, 72 ppi, 1× virtual canvas is a host
diagnostic surface, not physical HomePod metadata. Templates, iOS setup
automation and slimming are disabled for HomePod creation.

## Creating a machine

With a built bundle and a configured host:

```zsh
cli='/absolute/path/to/VPhone.bundle/Contents/MacOS/vphone-cli'
"$cli" vm create homepod-mini --device AudioAccessory5,1 \
  --iphone-source '/Users/insidegui/Downloads/AudioAccessory5,1_27.0_24J361_Restore.ipsw' \
  --cloudos-source '/absolute/path/to/cloudOS_23E5207q_Restore.ipsw' \
  --cpu 4 --memory 4096 --disk-size 32
```

The historical `--iphone-source` option accepts the HomePod IPSW. The catalog
also supplies its URL. Launchpad selects the HomePod preset and disables
templates/slimming; specified local IPSWs are inspected by manifest even when
renamed. The CLI also infers the device from a local or cached IPSW when
`--device` is omitted. An uncached remote source needs explicit `--device`.
For the manual prepare/restore pipeline, select `homepod-mini` with
`fw set-patches` before preparing. The guest family and preset ship in the
2.11 bundle/Launchpad series; Launchpad's minimum bundle version is 2.11.0.

## Validation

Validated on 2026-10-22 with four CPUs, 4 GiB memory and a 32 GB disk:

- The supplied IPSW's SHA-256 matches Apple's CDN metadata above.
- Native `fw prepare` completed with cloudOS 26.4 (23E5207q), retaining B520's
  tree and skipping GPU recovery. `fw patch` applied 241 records without an
  undeclared-patch warning. The existing research boot-chain identity was
  retained for restore.
- OpenAVB/OpenSEP DFU restore completed, including system volume sealing.
  CFW installation completed through Launchpad's installed helper, with the
  launchd cache gate and TVOS vphoned installed, and no patch failures.
- Three normal boots reached vphoned. On the second and final boots, using
  2.11 local bundles,
  `vm start --headless --wait` reported an answer after four seconds.
  `device.info` reports `model=AudioAccessory5,1`, `own_name=HomePod`,
  software 27.0.0, four CPUs, approximately 4 GiB memory and a NAT IPv4 address.
  Boot session UUIDs differed, confirming separate boots. The second guest
  answered again after more than a minute, without a reported panic.
- `processes.list` showed HPSetup, AirMusic, AirPodcasts, homepodsettingsd,
  homepodsensed, homehubd, homed, audioaccessoryd, audiomxd, airplayd and
  tvairplayd. This observes running services, not their functional correctness.
- The complete VPhone bundle and Launchpad build with Xcode MCP; bundle
  admission and signatures pass. Firmware identity/layout/patch regression
  suites passed (70 tests, four unavailable reference fixtures skipped).
  All 102 archive tests passed. Core ran 658 tests: 657 passed on the full
  run; an unrelated TCP throughput timing test failed under concurrent VM/disk
  work and passed on an isolated retry. Launchpad IPSW, machine identity and
  version/binding regression harnesses passed. New localized strings compile.
  The shared `VPhone` scheme exposes the existing complete-bundle target for
  the documented build command. A CLI validation probe confirms that the local
  HomePod IPSW is recognized without `--device`, before any VM is created.

The research VM is `~/.vphone/machines/homepod-mini`. Evidence is retained under
`.build/homepod-research/` (prepare, patch, restore, CFW, both guest identities,
process lists and boot results); its console is
`~/Library/Logs/vphone-launchpad/homepod-mini.log`.

Local audio output is verified on the Mac's selected speakers; see
[HomePod audio](../Guest/homepod_audio.md) for the native identity, HAL mode
and 48 kHz endpoint requirements. Microphone capture, Siri, AirPlay playback,
activation and pairing with the Home app have not been validated. The top-cap UI described
below replaces the diagnostic framebuffer for interactive HomePod windows.

## Top-cap display

The HomePod preset additionally selects `system-homepod-exp-top_cap`. On a
stopped existing machine, `cfw update-environment` installs this device without
a restore, recovering its metadata from the retained original board tree.
Disabling the patch removes the configuration and adapter and restores the
backed-up SoundBoard executable. Other presets leave this device off.

The donor node `/arm-io/dockchannel-rtp/rtp-transport/display` supplies 19 RGB
positions: twelve outer LEDs, six inner LEDs and one center LED, at 12-bit
depth and hardware version 3. `MDXCoords` and `MDYCoords` are unsigned
little-endian Q16.16 positions in the full cap's unit square; their unpopulated
rim must not be stretched away. `MDRingCoords` contains integer ring indices.
The installer retains these five raw properties in
`/usr/share/vphone/HomePodDisplay.plist`; the host has no hardcoded LED layout.

MiniDisplay matches consumer HID usage page 12, usage 1. Its report 2 is a
packed 245-byte output report: one-byte report ID, eight-byte mach timestamp,
then two 118-byte banks, each with two UInt16 icon words and nineteen RGB
UInt16 triples. All multi-byte values are little endian. Bank 0 contains
Siri/transient output, bank 1 the always-on layer; the volume icons use bank
0's two words. Peppy expands the physical depth to a 16-bit wire range;
RGB and icon words both scale by 65535, independently of the 12-bit tree value.
Its initializer reads `kMDDisplayMaxBitDepth` (16) at 0x1a6a3787c, and
`submitPixelBuffer` computes the shift from the physical depth at 0x1a69dbda8.
HomePodDisplayService
already applies brightness and gamma before submitting frames. The property
named `MDDisplayBrightness` controls driver processing, not master intensity.

These observations come from this IPSW's MiniDisplay and
HomePodDisplayService shared-cache images, extracted with relocation and ObjC
metadata repair. Their extracted SHA-256 values are respectively
`26d787575f4292a496cae7f9e341ae53134a8b482d4d23c5c970ea65a5828157` and
`a958fb05e8f2b4774a2542256bfe803a078f3574adf9cdad96a7468d56ce2354`.
Reveal points are `MDInterfaceHID._readRegistryProperties` (0x1fb5f56b0),
`displayCount` (0x1fb5f4160), `deviceAdded:` (0x1fb5f3f88),
`MDFrame.initWithInterface:pixelInfo:` (0x1fb5f31b8),
`HPDSLEDController._processBrightness:` (0x1a69d9cb0) and
`Peppy.submitPixelBuffer` (0x1a69dba30). Analysis and runtime artifacts are
under `.build/homepod-ui-research/`.

vphoned publishes an `IOHIDUserDevice` with that metadata, receives the native
output reports, and exposes the latest immutable snapshot through
`homepod.display.state`. MiniDisplay tests the reserved `IOClass` property in
both discovery and property reads. A guest probe confirmed that the virtual
HID API accepts this descriptor but rejects an `IOClass` override; setting it
after creation returns unsupported (`0xe00002c7`). The SoundBoard-only adapter
therefore recognizes exactly `vphone-homepod-mini-display`, performs the normal
retain/open/semaphore discovery sequence using ObjC runtime ivars, and supplies
the MiniDisplay class identity for that device. Other devices and other property
reads retain the original implementations. A failed frame submission on that
virtual handle triggers immediate HID enumeration, throttled to once per second,
and retries the original frame on a replacement device. This handles vphoned
restarts; the native interface otherwise retains its stale handle indefinitely.
The original `submitFrame:error:` (0x1fb5f2ff8) forwards `IOHIDDeviceSetReport`
errors, and `_findDevice` returns early while `_device` is non-null. Recovery
does not call `_findDevice`, whose absent-device wait can block for 30 seconds.
Frame generation and native report submission remain Apple's. The adapter uses
a signed load command in SoundBoard and
preserves its original entitlements.

The Mac window defaults to 480 × 480 points and displays a circular diffuser using runtime-compiled Metal 4
shaders (with the same shader on the macOS 15 Metal compatibility path). It adds
both guest light layers, blends neighboring emitters through a normalized
two-scale point-spread function, attenuates the opaque edge, and draws the
independent +/- channels as etched markings. Its diffuser, color response and
layer composition are visual approximations; the exact optical/hardware
composition is not established by the inspected userspace code. No optional
Xcode Metal compiler download is needed to build the application. Delivery keeps one snapshot request
in flight at up to 60 Hz, drops intermediate frames, blanks on connection loss,
and pauses requests while minimized. No host animation substitutes for output.
The accessible +/- controls send consumer volume HID down/up (0xE9/0xEA),
including holds and immediate releases on focus loss. They omit focus rings
while retaining keyboard and accessibility activation. Quick taps last at least
700 ms after the guest acknowledges key-down. Timing from the mouse event can
collapse a tap's down/up into adjacent RPCs when input delivery is delayed.
This preserves a usable consumer-key hold for instantaneous mouse/AX taps.
The center touch surface has no
input mapping yet and is excluded from accessibility/tab navigation.

### Top-cap validation (2026-10-22)

- The full `VPhone` bundle builds, passes its admission phase and passes
  `codesign --verify --deep --strict`. Xcode MCP runs passed 39 selected
  firmware/patch-selection tests and all eight `HomePodDisplayTests`.
  `VPhoneDaemon/Tests/run-homepod-display-tests.sh` checks report boundaries,
  both banks, icon channels and full 16-bit normalization. The guest-component
  identity harness checks virtual-device discovery, ordinary property/error
  forwarding, duplicate discovery, replacement after failure and retry throttling.
- On HomePod Software 27.0 (24J361), SoundBoard submits native report 2 with
  length 245, nineteen RGB entries per bank and zero rejected reports. The Mac
  cap visibly follows its white volume HUD and independently lit +/- channels.
  Held clicks change the guest's `Audio/Video` volume in both directions.
  A trace of 1 ms mouse clicks confirmed paired RPCs with at least 700 ms
  between key-down acknowledgement and key-up. Two such clicks per button
  changed volume from 0.48 to 0.58 and back to 0.48. Initial individual presses
  sometimes lit the HUD without changing volume despite valid input delivery;
  the cause inside the guest has not been established. No host-side volume
  setter substitutes for HID input. The native-button probe also verifies
  paired transitions from standard button and accessibility actions.
- Killing/restarting `com.vphone.vphoned` recreates the HID device. With the
  recovery adapter installed, native reports resume without restarting
  SoundBoard or the VM; an additional volume press produces another report.
- A complete opt-out/update/boot cycle reported an unconfigured display,
  removed SoundBoard's added load command, and preserved its original
  entitlements byte for byte. Restoring the original HomePod preset and updating
  the guest environment brought the display back. The saved patch selection
  before and after that cycle is identical.

Runtime artifacts for these checks are under `.build/homepod-ui-research/`.
Siri activation and its multicolor animations remain unvalidated; report and
renderer tests exercise RGB channels without claiming those services work.

The subsequent Metal rendering, complete SoundBoard debug controls, and optional
setup-completion helper are documented in
[HomePod SoundBoard controls and setup](homepod_soundboard_controls.md). These
changes have offline validation; the live results above apply to the preceding
HID/display implementation, not to the new helper or debug effects.

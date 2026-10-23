# HomePod 27.2 and native Sound Glow

The candidate follows the Apple TV OTA approach: restore the HomePod mini's
27.0 IPSW, use the full 27.2 OTA for System, then apply the selected guest patches
to that System. Nothing has been installed into the running 27.0 VM. Live boot
and Sound Glow verification remain pending administrator availability.

## Donor identity and acquisition

Apple's Pallas metadata advertises a full, unencrypted ZIP OTA for
`AudioAccessory5,1` / `B520AP`, version 27.2. It reports asset build `24K6120`;
the archive's own SystemVersion is **24K120**. The catalogue and staged target
identity use that actual OS build. The original same-device 27.0 / 24J361 IPSW
supplies the restore base; there is no 27.2 HomePod mini IPSW in the catalogue.

The Apple URL is
`https://updates.cdn-apple.com/2026FallFCS/b191c01c-8e6e-4b74-8b84-015131f696b8/com_apple_MobileAsset_SoftwareUpdate/861a9e7426795ddb3eac86cd0b089e5bf7939258.zip`.
The downloaded 3,051,441,612 bytes have SHA-256
`72830cc7ea154fbb6fa26904d6b527977a5d35fe8130e1fcd027ae9e0243507a`, matching
Apple's metadata. Native catalogue/archive code supports this ZIP; the external
`ipsw` tool used to extract analysis artifacts is not a runtime dependency.

## Why 27.0 cannot enable this with a preference

The current 24J361 `NowPlayingCap` SHA-256 is
`213c5c236ac0dacecf0cca35dca28b743abe59a56303431ccccf29d5dbda977b`.
Its exposed settings contain `depictNonGroupLeaders`, but it has no accessory
media UI setting provider, artwork-fetch service or color extractor. Its CapKit
`CAPAnimationEffect` description handles Siri, pulse, intercom and off; it lacks
the media and soundscape cases used by the later app. Donor REA evidence:
`ev_6d68dc5a122be207d422ad766cb85318570434b8259bd4012f117347bf6acfd7`.
The old app's pulse selection is recorded as
`ev_302f2ba4359e26acda6210e7b142d028577fb98d6e9c10ca960483780672127f`.

The 24K120 app SHA-256 is
`b5f33c09cbc46b973ff5799ff0a192792e54d4390a2005ac14e322a9fb5a5525`.
It adds `ArtworkService`, `ArtworkFetcher`, `ColorService`, `ColorCache`,
`MediaColors` and `AccessorySettingProvider`, plus native CapKit media and
soundscape effects. The extracted CapKit SHA-256 is
`344968deda3cd5d81c272133c341085b9222b5677099a3ad2815835edcb168a1`.
This is a matched complete userland, not a cross-version app/framework graft.

## Native enable path

`_TtC13NowPlayingCap24AccessorySettingProvider` owns an NSInteger `mediaUI`
property, initially zero. Its getter and setter are ordinary Objective-C
entry points. HomePodSettings updates for `HPSKeyPathMediaUI` flow through the
setter; native Now Playing model initialization and updates compare the getter
to exactly **1** to enable expressive media UI. Evidence:

- Getter: `ev_7290a7682be1da8faddf0b7d3705eca45c221524ced0574336c451dac306c976`.
- Initialization: `ev_e8137e7f3167abfe4aa689a5face6a38c7ac0bc965a5dab4bec0a522dfc6c3b4`.
- Home setting delivery: `ev_48e261439e6344b529203e398bb151bf5b761c93f6b195a2521c3026d53266b3`.
- Model initialization: `ev_0c99db6bbc5e6bac99ab2d7404ee88da7912e7d20b7130e4ed0634a589f27e33`.
- Model update: `ev_fd1d7a9257b0593d548a5ddb37da606fecec2d5742012c50a075d10e6113e25b`.
- Native rendering: `ev_27f1ff4748bf169c4b5e3828643dbec305487df8d6d25c3f90b591eef8c55db8`.

The rendering function builds `CAPAnimationEffect.media` from extracted UIColor
arrays, or a native soundscape effect, and assigns `currentLEDEffect`. Its
expressive branch acquires the native brightness assertion. The observed
CAPAnimation initializer passes `audioTapping=false`; merely forcing the old
SoundBoard audio-tapping flag is not an implementation of this feature.
The app's Swift feature enum names `Home.homePodTopCap`; the 24K120
`FeatureFlags/Domain/Home.plist` marks `HomePodTopCap` FeatureComplete. The
candidate leaves that native flag intact.

## Selected patches and guest ownership

Both patches are optional, HomePod-only, version-gated to 27.2 or later, and
selected by default only in the `homepod-mini` preset. Standard, Experimental
and the TV presets exclude them. `system-homepod-exp-sound_glow` requires
`system-vphoned-boot-install` and `system-homepod-exp-top_cap`.

The Sound Glow installer writes an Enabled policy and injects the existing
`libvphonehomepoddisplay.dylib` into **NowPlayingCap**. Its constructor recognizes
that process and installs only the narrow `mediaUI` getter adapter after checking
the getter/setter ABI. Other process initialization retains the existing
SoundBoard display, Siri speech and welcome behavior. A missing or changed
native class refuses installation rather than inventing frames or calling an
unknown ABI.

While enabled, the getter returns native value 1. The original setter still
receives Home updates; disabling policy exposes the actual setting again.
Deselection restores the backed-up native executable, reseals the app and
removes the policy. No Home account or accessory preferences are rewritten.
There is no host scheduler, synthesized LED animation, artwork scraper, global
MobileGestalt change or audio-session modification.

## Verification boundary

Native policy tests cover process isolation, absent/changed ABIs, idempotent
installation, native setter preservation and opt-out. The existing display
identity harness passes with the new source linked. Firmware catalogue and
resolution checks cover version gating, default selection, TV rejection and
missing prerequisites. Archive tests cover ZIP metadata ordering and rejection
of duplicate entries; existing archive path/size bounds remain in force.

Static native control flow establishes the candidate's enable mechanism; it
does not prove real AirPlay artwork delivery, brightness, animation timing or
27.2 boot compatibility. A live candidate must establish all of those, then
verify pause/resume, a change between distinctly colored album covers, Siri
interruption and return to music, policy opt-out and restart persistence. The
original 27.0 VM and its once-only welcome claim must remain recoverable.

Analysis artifacts and saved REA snapshots live locally under
`.build/homepod-sound-glow-research/`. They are not shipped runtime resources.

### Completed offline checks

- Xcode MCP: 24 OTA archive tests, 12 firmware catalogue report tests, and 46
  firmware declaration/resolution tests pass. The latter include 27.2 preset
  selection and Sound Glow dependency checks.
- Native state/welcome, Siri speech, Sound Glow and display harnesses pass.
- The complete Debug `VPhone` bundle builds and passes bundle admission. Xcode
  MCP omits the aggregate scheme, so the full bundle uses the repository's
  documented xcodebuild fallback with `/Applications/Xcode.app`.
- Real native `fw prepare` succeeds in the repository-only scratch library,
  streaming 51 chunks and validating all 6,721 hard-link destinations. It writes
  `OTAUserland/Version.plist` as AudioAccessory5,1 / 27.2 / 24K120. The base
  `iPhone-BuildManifest.plist` remains 27.0 / 24J361, as required for restore.
- Real `fw patch` succeeds across all 11 components with 241 patches and no
  undeclared-patch warnings. The plan records 27.2 over cloudOS 26.4 and selects
  both new patches along with the existing cap, audio, Siri and welcome patches.
- Read-only dry runs of all five selected shared-cache patchers pass against
  24K120: IOMFB finds 10 retargetable trampolines; lsd and libxpc find their
  semantic gates; maxSlide already fits; the missing lockdown function is an
  explicit supported no-op. No cache bytes were changed by these probes.
- The production Mach-O injector successfully adds the weak guest adapter load
  command to a separate copy of the 24K120 NowPlayingCap executable.

The prepared candidate is
`.build/homepod-sound-glow-research/machines/homepod-27-2`. Its Disk.img is a
new, unrestored VM. Firmware preparation/patching and raw payload staging are
complete; restore, CFW installation, boot and playback have **not** run. Logs
are `prepare.log`, `patch.log`, `bundle-build.log` and `*-dry-run.log` beside it
in the research artifact folder. The original running `homepod-mini` remains
bound to `2.11.0-local.3f1d474e` and software 27.0; it was not stopped or updated.

### Live continuation

On 2026-10-23 the separate candidate was moved into the normal machine library
as `homepod-27-2`, bound to `2.11.0-local.f2cd5cbf`, restored and installed through
Launchpad. Native SystemVersion and device.info confirm 27.2 / 24K120 and
AudioAccessory5,1. The display receives valid native frames, and the owner
confirmed clear Music/AirPlay audio. Initial playback remained white:
NowPlayingCap's ArtworkFetcher failed with MediaRemote error 47, because
`MRDestination.initWithOutputDeviceUID:` addressed the own device UID from
`MRDeviceInfoRequest.localDeviceInfo`, which had no discoverable endpoint.
The exact call flow is recorded by REA
`ev_d726ad0f2fbd4dfc638d64c09cff9cb19c9e36ccf3e0b3dae3b09e39148f5ecf`.

The candidate adapter now also intercepts NowPlayingCap's native
`MRPlaybackQueueRequest.performRequestForDestination:completion:`. Only a
request whose output UID equals that same native local-device UID is routed
to `MRDestination.localDestination`. Identifiers, dimensions, completion and
native artwork decoding/color extraction remain untouched. Other destinations
and policy opt-out retain the original call. All participating method ABIs
are checked before installation; the harness verifies local/remote/nil targets,
completion preservation and opt-out. This routing change still needs live
verification. No host artwork fetching or generated frames are involved.

Install the prepared bundle through Launchpad when authorization is available.
Use the returned installed version, preserving the default bundle and all other
VM bindings. Restore and install the prepared 27.2 candidate as a separate VM,
then verify boot, exact device/OS identity, audio and native top-cap delivery
before sending Music/AirPlay to it. Confirm native artwork colors change with
tracks and the animation reacts during playback, pauses/resumes, yields to Siri
and returns to music. Exercise Sound Glow opt-out through the patch selection
and environment update, then re-enable and reboot. Keep the original 27.0 VM
until the candidate passes these live checks.

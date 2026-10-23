# HomePod mini audio through virtio-snd

## Scope and current boundary

This ports the existing iPhone/iPad virtio-snd output transport to HomePod mini
(`AudioAccessory5,1`, B520, HomePod Software 27.0 / 24J361). The host already
configures `VZHostAudioOutputStreamSink`; the missing pieces are guest HAL
publication, tvOS bundle compatibility, and native routing identity. This work
does not add an audio-over-RPC stream or substitute host playback for guest PCM.

The owner authorized live tests. Launchpad installed the final
`2.11.0-local.b284734a`, passed host preflight, and updated `homepod-mini`'s
guest environment. Ordinary AVAudioPlayer playback reaches the Mac's selected
Studio Display speakers, and the owner confirmed **“Yes, clear tones.”**
Donor HomePod identity, B520 routing, the tvOS HAL driver and the 48 kHz
physical endpoint are verified. Both 48 kHz and 44.1 kHz source WAVs play
without a preferred-sample-rate override. The earlier failed iterations and
their discriminating probes are retained below.

### Product identity regression and audio-only correction (2026-10-22)

The donor product token used by that audio build also changes unrelated
MobileGestalt clients. An A/B boot using the same bundle and device tree,
changing exactly its 20-byte product token, restores the red LED replay with
the original virtual token (RGB/icons 0.749996), and blacks it with the donor
token. Native animation buffers remain red. `HPDSProductType.hasSiriGammaLUT`
now selects the physical gamma path; unlike the prior direct color path it
requires CoreBrightness input that the VM does not provide. The candidate
physical power-limiter exemption did not fix this and was removed.

Keep the original global token. VirtualAudio already offers a narrower
boundary: its resolver at `0x26d4ec` reads integer `ProductIDOverride` in
`com.apple.audio.virtualaudio`, takes the value directly at `0x26d528`, and
returns it at `0x26dc70` without MobileGestalt/acoustic-ID mapping. **4** is its
native B520 product enum, distinct from the iPhone's 8010 choice. The wrapper
at `0xc16f0` caches the result, so the preference must precede initialization
or audiomxd must restart. Other direct MG queries still exist in VirtualAudio;
this static evidence needs live playback validation with the original token.

The HAL plugin and vphoned now choose 4 for exactly AudioAccessory5,1, honoring
the existing explicit override including zero. Other guests retain their prior
policy. The boot-tree capability patch leaves product-id untouched. Every
preset blocks the old donor identity repair; updating an existing guest rebuilds
Preboot from its retained clean backup and reapplies the remaining repairs.
This VM's backup contains the original virtual token. A boot baseline already
containing a donor token is not reconstructed by disabling that repair; retain
its original research tree before migration. No display shim changes remain.

The owner initially deferred authenticated bundle updates. The failed display
candidate remained installed until they returned; the final audio-only build's
live results are below. Investigation artifacts are under
`.build/homepod-audio-research/display-regression-*`.

Local verification: all **88** focused Xcode firmware tests pass, including
the original-token fixture, all-preset donor-repair exclusion, shipped/built-in
preset agreement, and shared Preboot inverse composition. Four audio transport
harnesses and the unchanged display identity harness pass. The full `VPhone`
bundle build and `codesign --verify --deep --strict` pass. The final bundle is
`.build/XcodeBundle/Build/Products/Debug/VPhone.bundle`.

A guest-only read/write Preboot remount was rejected by automatic approval
review because it changes boot-volume protection. That probe was not executed
or retried. The temporary audio override and other diagnostic preferences were
restored, and the VM was stopped while waiting. The final source contains no
display workaround. The later authorized Launchpad update applied the normal
Preboot inverse, without the rejected guest-only remount.

### Audio-only live validation (2026-10-22)

Launchpad installed `2.11.0-local.40cd1d45`, passed preflight and updated only
`homepod-mini`. Its first cold boot answered vphoned after four seconds. The
entire installed 77,138-byte personalized Preboot tree is byte-identical to
the original saved before the audio identity change (SHA-256
`65716513bd65ff960c1670a5586658ed8e9dc8894e13c21ac0428288567a6d0e`).
The native mobile probe reports `MGGetProductType=3832856627` (`0xe474c033`),
with `ProductType=AudioAccessory5,1`, `hw.model=B520AP` and short model B520.
VirtualAudio's separate stored `ProductIDOverride` is integer 4. Driver startup
logs confirm that value was present before VirtualAudio loaded.

The same red replay previously blacked by donor identity now reports RGB/icons
0.749996, with no rejected HID reports or error, and is visibly red in the Mac
window. Native `identify`/`On` produces white inner-ring and center LEDs near
full scale. A second cold boot again answers after four seconds, retains route
4 and produces the native identify output. No display shim changes are needed.

Ordinary AVAudioPlayer sessions play 48/44.1/48 kHz source WAVs through Speaker
`PuffinOutput` at a 48 kHz physical rate. The owner confirms **“Yes, clear
tones.”** A VM-scoped unmuted host tap records 1,142,314 nonzero Float32 samples,
peak 0.00598199 and RMS 0.00216457, over about 11.9 seconds of active content;
the tap and private aggregate are destroyed at exit. The first run's transfer
summaries have 60/56/70 writes, no starvation, and 49,152 dropped bytes in the
first cycle only. The repeat after a second cold boot has **63/59/56 writes,
zero starvation and zero dropped bytes in every cycle**. audiomxd remains PID
116 before and after that repeat, without a manual service restart.

The bounded 28-second error capture contains 281 entries and is not truncated;
none match the prior speaker-DSP buffer overruns. It still contains zero-channel
and 14-channel converter errors; microphone routing remains outside this output
port's validated scope. These short tests do not establish long-duration clock
accuracy. The replay/spinner/identify diagnostics are cleared, probe jobs are
unloaded and temporary files removed. The VM remains running on the corrected
bundle, with the library default and other VMs unchanged.

Evidence: `audio-only-live-{tree,native-identity,red-display,identify-display,
playback,driver,audio-errors}.json`, `audio-only-host-tap.log`, and
`audio-only-second-boot-{display,playback,driver,audiomxd-before,audiomxd-after}.json`
under `.build/homepod-audio-research/`.

## Native reveal procedure

The donor filesystem is the already-extracted IPSW image
`.build/homepod-research/043-04683-522.dmg`, mounted read-only for inspection.
`VirtualAudio.plugin/VirtualAudio` SHA-256 is
`fb9a18193dc49b14ef93dd4cc961f36ab4432db2aa55f520fb72665bf2e55774`.

1. Inspect `ProductIDOverride` and the product resolver at `0x26d4ec`, then its
   native product mapping at `0x6ce44`. The existing VM reports native product
   `0`; startup logs select unknown handlers and route the default VAD through
   `Null_Device`. The temporary mobile probe confirms `caulkShortModel=B520`,
   `hw.model=B520AP`, `ProductType=AudioAccessory5,1`, and caulk device class 7,
   but `MGGetProductType=0xe474c033`. Correct model strings alone are insufficient.
2. Read the donor's actual 20-byte `/product/product-id`. In the donor
   libMobileGestalt product table it matches row 17 at `0x1817b4680`; its
   product enum is `0xc79439ac`. `_MGGetProductType` returns the matched row's
   field at offset `0x18`. This comes from the donor tree, not a guessed value
   or a replacement instruction. libMobileGestalt SHA-256 is
   `48385776b53ca8ebc5705dd3d1efa2c5b316a22d5de7ace74c71c108b2df96ba`.
3. Follow the VirtualAudio comparison at `0x6dcd4` through `0x6dce4`: this enum
   maps to native VirtualAudio product **4**. The factory at `0x20063c` sends
   products 4/5 through `0x413698` into the B238 settings implementation at
   `0x40b508`. It reads the short hardware model to find the B520 tunings the
   donor already ships. There is no HomePod use of the iPhone `8010` override.
4. Follow the physical device factory's `PuffinOutput` entry (`0xbf62c`) and
   Puffin output creation (`0x1fed4c`). It requires an output stream and creates
   the built-in speaker port. Publish the existing virtio output under this
   recognized UID. An arbitrary `VPhoneVirtIOSound:0` UID is not that endpoint.
5. Extract HomePod's AudioServerDriver and compare every class/selector used by
   the driver. All nine imported Objective-C classes are exported. The native
   stream sample-rate callback returns `BOOL`, the stream-format initializer
   takes an ASBD pointer, the Boolean control uses a Boolean value, and the
   selector-control setter returns `BOOL`. Those declarations and call sites
   now match. AudioServerDriver SHA-256 is
   `4f380fe557715e18c2bf51259d80f637537d32396a19b5cd5669cfb95fdf37d4`.

REA evidence includes `ev_57bf62b3753a8091e7ca4878988639c3e722480486db12880a57a79dc54313a3`
(product resolver), `ev_2ab6df5ddf4508042cc86b9e0cc85e060b88a7e91125531712a9b0b53adebde1`
(native product mapping), `ev_e1343681ede554b3c1e31304a7e18c2462007a5a28246e9f6b41611f5d4d1609`
(routing factory), `ev_031fc0505e106fc2a833b178bbc8ceab3e632e120cd7cae3edcb05012e557da7`
(B238 settings), `ev_d22194fc9033bb221486cd06fc6817a89125cd5c6745345c004a923d9d4a7681`
(device factory), and `ev_f61b6d22824277dae53b78ba7d327f86ec86644495e86c2b282deb1bfe1bbdc9`
(Puffin output creation). These are reconstructed static control flow. Native
disassembly and exact donor table reads corroborate the steps; they do not
establish successful execution of the changed route.

The ledger, donor hashes, original disassembly, extracted ASD method encodings,
reproducible product-table probe, native diagnostic records, and closed REA
snapshot are retained under `.build/homepod-audio-research/`.

## Initial implementation (superseded identity policy)

`preboot-homepod-exp-audio_product` copies the validated donor product digest
into the restored Preboot device tree. It is declared, optional, HomePod-only,
27.x-gated, and was selected only by `homepod-mini`. It joins the existing Preboot
repair composition and its inverse rather than overwriting unrelated tree
repairs. New boot trees also receive that digest through the HomePod product
patch. The literal donor digest is never embedded in patch logic.

`homepod-mini` also selects the existing `system-virtiosound-cfw-hal_plugin`.
Installation retargets the shared arm64e driver to tvOS, sets its supported
platform metadata to `AppleTVOS`, signs the edited binary and reseals the whole
HAL bundle. iPhone/iPad installation retains the original payload. Deselecting
the driver removes the added bundle; deselecting the identity repair restores
the baseline product property through Preboot repair composition. An older
guest's baseline contains the old virtual product token. A newly restored
guest whose boot-tree product patch already copied the donor token retains
that correct token on repair opt-out; changing that boot-chain choice requires
firmware patching and restore.

The output UID is `PuffinOutput` for exactly `AudioAccessory5,1`, independent of
the iPhone routing override. Existing explicit UID preferences still win. The
shared float PCM, resampler, queue ownership, volume/mute controls, start/stop
drain and idle-timer behavior are reused. HomePod microphone routing is not
ported and its input is not presented as a physical Puffin microphone array.
Apple TV retains its original exclusions; none of the iPhone VirtualAudio
instruction or tuning patches is enabled for HomePod.

HomePod output advertises only its 48 kHz wire rate in both device and stream
formats. The native B520 speaker graph overruns its 1024-frame input at a
44.1 kHz physical rate. CoreAudio converts 44.1 kHz source audio before the
physical endpoint; iPhone/iPad retain the driver's alternate physical rate.

The HomePod cap separately uses a 480 × 480-point default content size and
suppresses volume-button focus rings while retaining keyboard, pointer and
accessibility input semantics.

## Validation

The existing four virtio transport/clock/converter/latency harnesses pass. The
ASD declaration corrections build for arm64e with `-Werror` and verify as a
signed HAL bundle. Xcode MCP builds the enlarged cap and focus-ring changes.
All 65 focused firmware identity, repair composition, platform and preset tests
passed in Xcode. The complete signed VPhone bundle builds and passes strict
signature verification. A copy of the actual stopped guest's Preboot IMG4
passed dry-run, exact 20-byte substitution, metadata preservation and repeated
application checks; the mounted source was read-only and remained untouched.

The actual cap view and Metal 4 renderer also passed a host UI probe at
480 × 480 points: no focus ring while active or focused, named accessibility
buttons, paired Space/Return presses and releases, accessibility activation,
and immediate release on focus loss. The pre-existing Tab chain loses its
explicit next link when attached to an AppKit content view; this change does
not modify keyboard traversal.

### First updated-bundle live findings

The guest answered vphoned after five seconds. A native mobile probe reports
`MGGetProductType=0xc79439ac`, `caulkShortModel=B520`, and
`hw.model=B520AP`. audiomxd reports `ProductID to int is: 4`, loads B520 graph
configurations, initializes VirtualAudio with status 0, and activates the
driver's `PuffinOutput` with its volume and mute controls. It publishes a
`pspk` port for that endpoint.

Route construction then throws `who?` while reading `[mode/glob/0]` from
`PuffinOutput` (`RoutingHandlerUtilities_Aspen.cpp:385`), leaving the aggregate
on `Null_Device`. A temporary AVAudioPlayer probe accepted 48 kHz, 44.1 kHz
and repeated 48 kHz tone playback, but reported an empty output route; the
virtio log contains no output writes. Those API success values do not establish
sound. This identified the next property contract to repair.

The native remote-property callback at `0x25784c` reads a four-byte UInt32
(`0x257988…0x2579d0`), then throws at source line 385 on a failed read or
incorrect size. B238 constructs the `mode/glob/0` property at `0x4149c8` and
`0x414a3c` with synchronous updates. Its desired values are the native FourCCs
`defa` (`0x40e220`), `raww` (`0x40e26c`), `tphn` (`0x40e2b8`) and `meas`
(`0x40e304`). The driver now exposes this raw-byte custom property only on
HomePod output, appends its 12-byte `{mode, raww, 0}` descriptor to the inherited `cust` list,
preserves synchronous readback atomically, rejects other modes, and notifies
through the verified `ASDPlugin changedProperty:forObject:` method. This
represents physical processing-mode selection; it does not apply board DSP in
the host transport.
The native ASD `addCustomProperty:` rejects a zero payload data type; its
`cust` getter emits `raww` without translating it to the public SDK's zero
`None` value (`ASDObject` `0x1a93d9398…0x1a93d93c0`). No new private class
initializer or property callback subclass is needed.

### Corrected mode-property live findings

Launchpad installed `2.11.0-local.61d08ba5` and updated only `homepod-mini`;
the library default remains 2.10.1. The guest answered vphoned after five
seconds. After a diagnostic audiomxd restart (PID 184), the driver receives
`mode/glob/0` queries and native routing builds a `PuffinOutput` aggregate.
AVAudioPlayer reports a real `Speaker` output with UID `PuffinOutput` for
48 kHz, 44.1 kHz and repeated 48 kHz source WAV files. The HAL selects
44.1 kHz for this playback category; the existing converter produces 48 kHz
virtio output. This verifies both source formats, not a forced switch of the
physical device to both nominal rates.

Two three-tone runs completed six separate start/stop cycles. Their stream
summaries report 56, 64, 58, 55, 63 and 59 writes respectively, with **zero
starved and zero bytes dropped in every cycle**. The short-run host-rate
estimate varies, so these counters do not establish long-duration clock
accuracy. The guest's software volume control accepts 0.35 and was restored
to its original 0.53; its route remains `PuffinOutput`. audiomxd is still
running as PID 184 after both runs, and no audiomxd report appears in the
mobile CrashReporter inventory. This iteration still lacked host listening
confirmation. The Mac output was unmuted at 3%; the host volume
was not changed. The temporary playback job, binary and result were removed
after preserving the host evidence, and guest volume was restored to 0.53.

Evidence: `live-mode-{install,update}.log`, `live-mode-boot.json`,
`live-mode-play-results.json`, `live-mode-repeat-driver.json`,
`live-mode-repeat-volume.json`, and `live-mode-audiomxd-service.json` under
`.build/homepod-audio-research/`.

### Silence diagnosis and 48 kHz endpoint correction

The owner reported no audible tones. Guest transfer counters alone had been
insufficient: the captured native `b520_speaker_general` graph logs contain
315 buffer overruns in the first run and 435 in the repeat. Each attempts to
copy 4,460 bytes from a 4,096-byte buffer (`Utils.cpp:517`). This is 1,115
Float32 frames, the rounded 1024 × 48000/44100 conversion. Mute and policy
mute were cleared; the driver gain was 1. The source WAV sample rate had not
changed the 44.1 kHz physical rate.

A temporary probe explicitly requested a 48 kHz AVAudioSession before
activation. All three source WAVs then report `sessionSampleRate=48000`,
native DSP buffer errors drop to zero, and virtio reports 63/59/54 writes with
zero starvation and drops. A private CoreAudio process tap captured only
`vphone-vm` and its virtualization service, with `CATapUnmuted`, preserving
normal playback. Over 30 seconds it measured 1,139,358 nonzero Float32 samples,
peak 0.00630998 and RMS 0.00211070. The tap and temporary aggregate were
destroyed afterward. This establishes nonzero PCM reaching the Mac audio
service for that explicitly configured session.

The driver now withholds the 44.1 kHz physical format only for HomePod output,
so an ordinary session cannot select the failing rate. It leaves iPhone/iPad
rate support and HomePod input unchanged. The finished bundle builds and
passes strict signature verification. The subsequent ordinary-session test
below verifies the permanent change. Evidence:
`silence-dsp-findings.md`, `live-force-48k-{results,syslog,driver}.json`, and
`host-tap-48k.log` in the evidence directory.

### Final ordinary-session playback

Final build `2.11.0-local.b284734a` boots to vphoned after five seconds. The
driver advertises `48000 Hz nominal (48000 wire, 0 advertised too)` for
`PuffinOutput`. The unmodified playback-session policy selects 48 kHz for
48/44.1/48 kHz source WAVs; every run reports a `Speaker` output with UID
`PuffinOutput`. There is no `setPreferredSampleRate:` call in this final probe.
Its three start/stop summaries show 58/54/63 writes, zero starved buffers and
zero dropped bytes. A repeat exercises the same path after stopping.

The VM-scoped host tap measures 1,153,218 nonzero Float32 samples over about
12 seconds of tone content, peak 0.00630807 and RMS 0.00230651. CoreAudio
identifies the active output of the virtualization process as **Studio
Display Speakers**. The owner confirms clear tones on that output at their
chosen 31% Mac volume. The tap's simple zero-crossing statistic is affected by
low-level DSP output and is not used as a pitch measurement.

The full-level unified log reached its 5,000-entry cap, so its zero matching
DSP overruns is only a bounded observation. A separate error-level repeat
was interrupted by an unrelated host console auto-scroll crash; no complete
error log is claimed for that repeat. The crash stack reaches
`VPhoneConsoleView.scrollToNewest` during a SwiftUI table update. The owner
explicitly deferred this crash, and console code is unchanged. The temporary probe job and files are
removed after host evidence is retained. The host tap and private aggregate
are destroyed at probe exit. The research VM remains on the final bundle;
the library default and other VMs retain their prior bundles.
After the deferred console crash, the same bundle booted again to vphoned
after four seconds. All three temporary probe paths were confirmed absent,
and `audio.state` reported an unmuted Audio/Video volume of 0.63. Evidence is
in `live-cleanup-boot.json` and `live-final-audio-state.json`.

Final evidence: `live-fixed-rate-{install,update}.log`,
`live-fixed-rate-boot.json`, `live-default-final-{results,driver,syslog}.json`,
`host-tap-default-final.log`, and `host-processes-default-final.json`.

### Coverage limits

This validates local output, two source sample rates, repeated playback and
the observed software-volume path. It does not validate long-duration clock
accuracy, every native mode/category, HomePod microphone routing, Siri,
AirPlay, or Home pairing. Identity/driver selection and the shared Preboot
inverse are covered by preset/repair tests and an actual Preboot-copy smoke;
live opt-out/re-enable cycling has not been performed.

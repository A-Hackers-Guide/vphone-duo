# Guest audio through virtio-snd

`vphone-vm` has always configured a `VZVirtioSoundDeviceConfiguration` with a
host output sink and a host input source
(`VPhoneExecutable/VPhoneVirtualization/UI/VirtualMachine/VPhoneVirtualMachine.swift`),
and the guest never played a sound through it. Two separate faults stood in the
way. Either one alone is enough to keep the guest silent.

## 1. Nothing in iOS drives the virtio sound device

The cloudOS kernelcache (`kernelcache.research.vphone600`) carries the kernel
half. `com.apple.driver.AppleVirtIO` has a personality matching virtio device
`0x19` (virtio-snd):

| Key | Value |
| --- | --- |
| `IOClass` | `AppleVirtIOSound` |
| `IOProviderClass` | `AppleVirtIOTransport` |
| `IOVirtIOPrimaryMatch` | `0x00191af4` |
| `IOUserClientClass` | `AppleVirtIOSoundUserClient` |

The userspace half is a CoreAudio HAL plugin, and only macOS has one:
`/System/Library/Audio/Plug-Ins/HAL/AppleVirtIOSound.driver` (factory
`AVIOPluginFactory`, classes `AVIOPlugin : ASDPlugin`, `AVIODevice :
ASDAudioDevice`, `AVIOStream : ASDStream`). The guest's
`/System/Library/Audio/Plug-Ins/HAL` holds `BuiltinAudioPlugin`, `AppleAOPAudioPlugin`,
Bluetooth, AirPlay and USB plugins and nothing for virtio. The cloudOS 26.4 system
image has no HAL plugins at all, and the iPhone 27.0 image has none for virtio
either (checked in each IPSW's `.dmg.aea.mtree`, which is plaintext once the
`pbze` chunks are decompressed).

### The user-client protocol

Read out of the macOS plugin's arm64e slice. Every selector forwards one
virtio-snd request, so the structures are the virtio specification's:

| Selector | Call | virtio-snd request |
| --- | --- | --- |
| 1 | `IOConnectCallMethod`: 1 scalar (stream ID) in, 32-byte struct out | `PCM_INFO` → `virtio_snd_pcm_info` |
| 3 | `IOConnectCallMethod`: 1 scalar in, 24-byte struct in | `PCM_SET_PARAMS` (`virtio_snd_pcm_set_params`; header left zero, the kernel fills it) |
| 4 | scalar | `PCM_PREPARE` |
| 5 | scalar | `PCM_START` |
| 6 | scalar | `PCM_STOP` |
| 7 | scalar | `PCM_RELEASE` |
| 8 | `IOConnectCallAsyncMethod`: 1 scalar in, the PCM bytes as the input struct | TX transfer |
| 9 | `IOConnectCallAsyncMethod`: 1 scalar in, the period buffer as the output struct | RX transfer |

The stream count is the `AVIOSoundStreamCountKey` property on the
`AppleVirtIOSound` service. Async references use three slots, with the callout
signed with the zero discriminator (`paciza`) as any C function pointer is on
arm64e. The macOS plugin sizes a period as a twelfth of a second rounded up to a
page, keeps twelve periods, flushes whole periods every 1/24 s on a dispatch
timer, and only lets the I/O thread reuse a region once its transfer has
completed. Its device clock is free running from `mach_absolute_time`, with a
timestamp period of `rate × 260 / 1000` frames and safety offsets of 100 frames.

### `VPhoneVirtIOSound.driver`

`VPhoneGuestComponents/VirtIOSound` is the iOS plugin built from that protocol.
It is written on AudioServerDriver, the private framework `BuiltinAudioPlugin`
itself uses on iOS (its log shows `ASD_Initialize`); the classes are declared in
`VPVirtIOSoundAudioServerDriver.h` and bound through `AudioServerDriver.tbd`.
It publishes one HAL device per `AppleVirtIOSound` service and one output stream
per virtio output stream, at the format the device offers (32-bit float, 48 kHz,
2 channels from `VZHostAudioOutputStreamSink`). Input streams are left out, so the
host microphone is never opened. The virtio stream is released when CoreAudio
stops and the last transfer has come back, so an idle guest does not keep the
host audio device running.

`cfw install` and `cfw update-environment` install it at
`/System/Library/Audio/Plug-Ins/HAL/VPhoneVirtIOSound.driver`
(`system-virtiosound-cfw-hal_plugin`).

Two optional values in the `com.apple.coreaudio` domain exist for routing work
and are read when audiomxd loads the plugin: `VPhoneVirtIOSoundTransportType`
(four characters, default `usb `) and `VPhoneVirtIOSoundDeviceUID`.

## 2. VirtualAudio never finished initializing (iPad guests)

Restarting `audiomxd` in an iPad guest (ipad-pro-13, iPad17,3 / J820, iPadOS
26.6.2) and reading its log shows the HAL loading `BuiltinAudioPlugin` fine and
then VirtualAudio, the routing layer in
`/Library/Audio/Plug-Ins/HAL/VirtualAudio.plugin`, abort:

```
audio_dsp_manager  Found device acousticID = 8018
audio_dsp_manager  Device tuning directory not found: /Library/Audio/Tunings/AID8018
RoutingSettings_J98.cpp:804   Creating subport config for spatial recording
RoutingSettings_J98.cpp:805   PRECONDITION FAILURE (std::logic_error).
VirtualAudio_PlugIn.mm:2135  VA Init Status: 1
-CMVAEndptMgr- vaemGetVirtualAudioDeviceIDs: No Audio Device Available.  This is a serious error.
```

and every later session request logs `VirtualAudio PlugIn is not initialized yet`.
With no VirtualAudio device there is no audio route at all, which is also why
YouTube and bilibili in Safari would not start playing.

### What the routing code expects

The J98 routing settings (`sub_47420c` in the 26.6.2 `VirtualAudio`) build one
microphone sub-port configuration per recording mode the device advertises, and
each builder (`0x4988c0` spatial, `0x498ae0` multicam, `0x498d00` webcam) throws
when its mode is advertised but the configuration was not built:

| Mode | Advertised by |
| --- | --- |
| Spatial (stereo) recording | `MGGetBoolAnswer("DeviceSupportsStereoAudioRecording")` (`0x477698`), which libMobileGestalt answers from the *presence* of `IODeviceTree:/product/audio/stereo-sound-recording` (a copy-property call tested for non-NULL; `0x186ff4ee8` → `0x186fcfb20` in the host's copy) |
| Webcam recording | `AVGestaltGetBoolAnswer(AVGQ3J3FEVOOCNOKKTK3XQPUQ47DYY)` (`0x4776bc`), byte `0x11` of AVFCapture's per-board capability table, set for `J817-J818-J820-J821` |

For these boards (product IDs 195 and 196) the routing code skips its own
input-processing path ("Input processing disabled", `RoutingSettings_J98.cpp:400`)
and builds the configurations from the tuning directory named by the device
tree's acoustic ID (`0x491738` onwards: `AU`, `VAD`, `…_mic_peripheral_sender_all_mics`).
A real J820 has `acoustic-id = 2029`, and the iPad image ships
`/Library/Audio/Tunings/AID2029` (and `AID2028`).

For these boards (product IDs 195 and 196) the routing code skips its own
input-processing path ("Input processing disabled", `RoutingSettings_J98.cpp:400`)
and builds the configurations from the tuning directory named by the device
tree's acoustic ID (`0x491738` onwards: `AU`, `VAD`, `…_mic_peripheral_sender_all_mics`).
A real J820 has `acoustic-id = 2029`, and the iPad image ships
`/Library/Audio/Tunings/AID2029` (and `AID2028`).

### Why the guest had the wrong acoustic ID

`devicetree-cfw-product_audio_node` adds the D47 iPhone's `/product/audio`,
whose `acoustic-id` is 8018. That is right for an iPhone guest — the iPhone image
ships `AID8018` and `D47` tunings — but the iPad identity patches copy `/product`
properties from the iPad's own tree and never touched this child node, so an iPad
guest advertised J820's recording modes over tunings it does not have.

The first attempt here removed `stereo-sound-recording`. That cleared the first
failure, and the webcam builder failed next (`RoutingSettings_J98.cpp:855/856`).
The webcam answer comes from the board name itself, so the flags were never the
fault; the tuning directory was. That attempt is not in the tree.

### The fix

- `devicetree-cfw-ipad_audio`: for an iPad guest's installed tree, `fw patch`
  replaces `/product/audio` with the board tree's node
  (`DeviceTreePatcher.presentBoardAudio`): every property as the board has it,
  placeholders included, except the board's `AAPL,phandle`.
- `fw patch` now reads the board tree through the `FirmwareOriginals` stash, so a
  copy of `DeviceTree.<board>.im4p` stays in the VM folder after the restore tree
  is deleted.
- `preboot-cfw-devicetree_board_audio`: `cfw install` and `cfw update-environment`
  apply the same replacement to the restored Preboot `devicetree.img4`
  (`vphone-cli cfw patch-dt-board-audio <devicetree.img4> <board.im4p>`), taking
  the board tree from `FirmwareOriginals`. An iPad VM patched before this has no
  copy there; put the board's `DeviceTree.<board>.im4p` from its IPSW into
  `FirmwareOriginals/<restore tree>/Firmware/all_flash/` and run the environment
  update. An iPhone guest has no board tree there and is left alone.

## 3. Inside the precondition failure (follow-up session, 2026-10-02)

The acoustic-ID fix (§2) holds — a fresh `audiomxd` restart on ipad-pro-13 logs
`Found device acousticID = 2029` and loads the AID2029 configuration — but
`RoutingSettings_J98.cpp:805` still throws. ipad-mini-01 (J410, also iOS 26.6.2,
its own AID8018 present) fails at the same line, and pcc-research-01 (iPhone17,3,
iOS 27) fails at the analogous `RoutingSettings_N71.cpp:1167`. In all three:

```
PlatformUtilities_Aspen.mm:154   ProductID to int is: 195|196
RoutingSettings_{N71:1073|J98:400}   Input processing disabled
RoutingSettings_{N71:1166|J98:804}   Creating subport config for spatial recording
RoutingSettings_{N71:1167|J98:805}   PRECONDITION FAILURE (std::logic_error).
VirtualAudio_PlugIn.mm  PlugIn initialized ? 1 / VA Init Status: 1
```

`PlatformUtilities` ProductID 195 selects the N71 (iPhone) routing settings,
196 the J98 (iPad) ones — every current iPhone and iPad guest walks the
"input processing disabled" path, and on that path the spatial sub-port
configuration is never built while the mode is advertised, so the builder
throws and VirtualAudio never initializes. Since real hardware takes the same
ProductID branch, something the VM lacks — not the branch itself — keeps the
configuration from being built there.

### Disassembled mechanics (iPadOS 26.6.2 plugin, offsets in the file)

`/Library/Audio/Plug-Ins/HAL/VirtualAudio.plugin/VirtualAudio` is a standalone
arm64e Mach-O with its local symbol table intact — pulled from the running
guest with `files.read` (7,356,608 B; saved with the iOS 27 copy in
`~/.vphone/va-analysis/`). `otool -tV` on it gives:

* The three builders (`0x4988c0` spatial, `0x498ae0` multicam, `0x498d00`
  webcam) all follow one shape: if the mode is not advertised (`tbz w0,#0`)
  return NULL quietly; if it is advertised but `*(this->subportConfig)` is
  NULL (`ldr x8,[x19]; cbz x8`), log at J98.cpp:805 and throw
  `std::logic_error("Precondition failure.")`.
* The subport-config slots are constructor locals at `sp+0x1a70/0x1a78/0x1a80`
  (webcam/multicam/spatial), zeroed at `0x47452c-0x474548`.
* Advertisement inputs: `x24 = MGGetBoolAnswer(DeviceSupportsStereoAudioRecording)`
  captured at `0x47769c`, webcam answer stored `[sp+0xf8]` at `0x4776c0`;
  both feed the guard-dispatcher at `0x477c80…` (one-shot flags
  `0x6fc468…0x6fc4b8`) which calls the three builders at `0x4938c8`,
  `0x493914`, `0x493960`.
* Config-building blocks for the three modes do exist in the constructor
  (`0x48ee24` spatial → stores the slot at `0x48ef94`, `0x48f04c` multicam,
  web-cam variant near `0x48f378`, second multicam/webcam variants at
  `0x4916b0`/`0x491a78`). They look the configuration names up in the
  `graph_configurations.plist` database through `0x4d8be0` (misses log
  `DSPGraphConfig_Utilities.cpp:437 Graph collection missing expected key`
  and zero the output — that message never appears in any guest log).
* What was **not** found statically: the branch chain on the
  "input processing disabled" path that is supposed to fill the three slots
  before the guard-dispatcher runs. The obvious build blocks are reached from
  `0x4776f8 b.ne 0x48e8c4` — the branch for devices whose webcam is *not*
  advertised and whose ProductID is *not* 195/196. Manual tracing of the
  180 KB constructor did not close the gap; instrumenting a patched copy of
  the plugin (below) is the fast way to see which path runs.

### What VirtualAudio does with our HAL device

Nothing, so far. Its `HALDeviceManager` processed only `Null_Device`
(`DeviceFactory.cpp:144 Unhandled UID "Null_Device"`); device 37
(`VPhoneVirtIOSound:0`) is activated by the HAL but never "[Added]" to
VirtualAudio. Setting `VPhoneVirtIOSoundTransportType` to `vrtc`
(kAudioDeviceTransportTypeVirtual) changed nothing. Physical devices reach
the factory through a creator registry (`unordered_map` at `0x6da2f8`,
lookup `0x1cf0f0`, dispatch `0xe0c8c-0xe0dcc`) that the routing settings
populate (the N71 mic builder at `0x2be594` registers per-mic creators, e.g.
`bottom_mic2`), so until init completes there is no built-in device for a
speaker route either — fixing playback needs both the throw fixed *and* the
virtio device registered in that registry.

### Ruled out

* **Tuning-directory naming.** The AID2029 directory is used where it should
  be; `graph_configurations.plist` (`CommonData`: `tuningPath =
  /Library/Audio/Tunings/AID2029/VAD`, `tuningFilePrefix = ""`) maps every
  mic mode to graphs that exist (`stereo_recording` → `stereo_recording_no_tap`,
  `spatial_video_recording`, `multicam` → `multicam`). The
  `/Library/Audio/Tunings/J820/VAD/v201_speaker_*.dspg` lookups that fail
  (`RoutingSettings_Aspen.cpp:3287/1870/1889`, loader `0x4283d4`, called from
  `0x4310dc` with chainType `'clhs'`) are non-fatal, and no image ships a
  `J820` directory, so real hardware fails them too — they are not the blocker.
* **Stale MobileGestalt cache.** The cache directory is empty (the previous
  session's deletion stuck); answers are computed live. Writing
  `com.apple.MobileGestalt.plist` (the file libMobileGestalt actually opens —
  it logs `Could not open …/com.apple.MobileGestalt.plist` when absent) with
  `CacheExtra {DeviceSupportsStereoAudioRecording: 0,
  AVGQ3J3FEVOOCNOKKTK3XQPUQ47DYY: 0}` did not change the outcome: the
  device-tree-backed answer bypasses `CacheExtra` (or the full
  `CacheData`/`CacheUUID`/`CacheVersion` schema is required — those key
  strings are in libMobileGestalt).
* **Our device's transport type.** `usb ` → `vrtc` made no difference (above).

## 4. Root cause found and fixed: `ProductIDOverride` (same session, evening)

The missing input was the **ProductID**. `PlatformUtilities_Aspen.mm` derives
it in this order (`0x2fa638` in the 26.6.2 plugin):

1. A defaults key, read by `RunTimeDefaults.mm`: **`ProductIDOverride` in the
   `com.apple.audio.virtualaudio` domain** (its own debug knob —
   `Defaults key ProductIDOverride was defined to %u`, `0x2fa638`).
2. A table lookup over a MobileGestalt class answer — table at `0x50cfd0` =
   `[195, 0, 196, 199, 0, 198]`. These five values are **simulator/research
   classes**: every one of them makes the routing constructor take its
   "input processing disabled" path (§3: `pid ∈ {195,196}` or the
   `DisableInputProcessing` default — *another* `RunTimeDefaults` key,
   `0x2735d8` — forces it), which never builds the spatial/multicam/webcam
   sub-port configurations, so the builders throw.
3. Real hardware never reaches that table: `MGGetProductType` (`0x9135c`)
   maps the actual model to a real ProductID, and for acoustic-id devices
   the id *is* the acoustic id (`Product with AcousticID '%d' is handled`,
   chip range 2025–2035 → the J-boards).

The vphone600 research platform lands on **196** ("iPad simulator"), which is
in the skip-set — hence every iPad guest threw at `RoutingSettings_J98.cpp:805`
and every iPhone guest at `RoutingSettings_N71.cpp:1167`, while real devices
never do.

### The fix

```
vphone-launchpad-cli guest rpc <machine> settings.set \
  '{"domain":"com.apple.audio.virtualaudio","key":"ProductIDOverride","value":198,"type":"int"}'
```

198 (`0xc6`) is one of Apple's own class values (the table's sixth entry) and
the only one that satisfies both gates found:

* not 195/196 → the J98 constructor builds the mode configurations
  (`Creating subport config for …` at :804/:816/:855 all run, no throw);
* accepted by `ActuatorSettingsFactory_Aspen.cpp:172`'s ProductID switch
  (`0x36d4f0`) — overriding to the acoustic id 2029 fixes routing but throws
  `Invalid Product Type` there, killing init a few lines later.

Verified live on both iPad guests (audiomxd restart): `PlugIn initialized ? 2`,
**`VA Init Status: 0`**, no exceptions, and the route comes up — `VirtualAudio_Device: type vdef; id 65 … agg dev "VAD [vdef] AggDev 1"`, the
`ap:ha:nd:of:fd:ev-screen`/AP ports publish, and a ringtone preview in
Settings ▸ 声效与触感反馈 ▸ 电话铃声 produces real `AQMEIO_HAL` output
activity. One benign exception remains (`noct`/`crng` category lookup in the
routing database — 198's route set is a simulator's).

## 5. The route to the virtio device exists — it is called `PuffinOutput`

With init fixed (§4), `VirtualAudio_PlugIn.mm` processes every HAL device and
its `DeviceFactory` creates a `PhysicalDevice` only for UIDs it knows. Two
tables in the 26.6.2 binary decide:

* a device filter allow-list at `0x6b4668` — `Null_Device`, `Actuator`,
  `Halogen`, `Hawking`, `Flicker`, `Penrose` (the "AllowOnlyNull" filter mode
  in `HALDeviceManager`);
* a per-UID handler table built in the `0xe002c` device-state handler —
  `PuffinOutput`, `Actuator`, `AOP Audio-1`, `HP16Mic`, `Digital Mic`,
  `DigitalMic`, `Mic`, `Hawking`, `Flicker`, `Penrose`, `Halogen`, …

`VPhoneVirtIOSoundDeviceUID` (the plugin's existing knob) renames our device,
so each family was tried live by restarting `audiomxd`:

| UID | Result |
| --- | --- |
| `VPhoneVirtIOSound:0` (default) | `Unhandled UID` — claimed by nothing |
| `Halogen` | PhysicalDevice created, publishes `plqi`/`plqo` (LDCM) ports |
| `Hawking` | publishes `phki` input port only (mic family) |
| `AOP Audio-1` | ASD binds dependencies (`IOPAudioLPMicDevice`, `IOPAudioIOBufferDevice`), rtaid Detector node, no output port |
| **`PuffinOutput`** | **`pspk` speaker port published, routable, and the VAD aggregate is built with `master = PuffinOutput`; the vdef's stream then binds `actual strm: id 38` — our virtio stream — with `associated ports: { pspk; PuffinOutput }`** |

"Puffin" is the Apple-silicon host-audio codec family, and the research
platform is exactly a virtual Apple-silicon Mac — which is why its built-in
output device name slots straight into the iOS routing tables.

### The remaining crash

Playing a ringtone with the `pspk` route deadlocks `audiomxd` within seconds:
CoreMedia's `MXInitialize → FigVAEndpointManagerCreate →
vaemCurrentRouteHasVolumeControlListenerGuts →
CMSMUtility_GetCurrentOutputPortAtIndex` blocks on a mutex held across the
`ASDTDeviceManager` background thread (`AudioServerDriver`'s device manager,
the same layer whose `ASDTDeviceManager: Started background thread.` line
appears in every boot), then abort()s — and the poisoned state makes every
subsequent `audiomxd` launch die the same way (17 crash reports,
`~/.vphone/va-analysis/crash2.json`). Deleting the UID preference alone does
not stop the loop; a **guest reboot clears it** (verified: `audiomxd` back,
`VA Init Status: 0`, no new crashes).

Likely cause, to confirm next session: a `pspk` speaker promises CoreMedia a
volume-capable output port (`VolumeControl.cpp: Device PuffinOutput does not
support hardware volume range property` is logged and tolerated, but the
listener then blocks). Our ASD device must answer the volume/port property
queries a Puffin output answers — implementable in the plugin with the same
`AudioServerDriver` API. One instrumented build of `VPhoneVirtIOSound.driver`
logging entry/exit of its property callbacks while the `pspk` route is up
will pinpoint the call that never returns.

The direction suggested earlier in §4 — publishing through the
AudioServerDriver layer like `BuiltinAudioPlugin` — is already what
`VPhoneVirtIOSound.driver` does; the masquerade-by-UID experiments above are
the cheap form of it, and implementing the missing volume/port property
callbacks is the completion of that path. The iOS 27 binary
(`VirtualAudio-ios27`) is saved for the N71-side port of the same fix.

## 6. Playing past the first stop, at the right rate, without gaps (2026-10-03, night)

Three faults in the plugin itself survived everything above. Each was found on
a new iPad16,1 / 26.6.2 guest (`audiotest-ipad`) with counters the plugin now
writes to `/var/mobile/vpquery.log` at every stream stop:

```
stream 1: 237 writes, 0 starved, 0 bytes dropped, lead 2 period(s)
stream 1: 20.16 s, in 888832 frames (44094/s, hal 44100), out 967436 frames (47993/s)
```

`writes` are periods handed to the kernel, `starved` the ones that found the
device with nothing left in flight (a gap on the host), `in` what the HAL
handed the mix block and `out` what went to the ring.

### Every start after the first failed

Symptom: the first playback after audiomxd launches works; after any stop —
the screen turning off, the next ringtone, pausing in Safari — every start
ends five seconds later in

```
HALS_IOContext_Legacy_Impl::IsTimeRunning_Helper: Device PuffinOutput is not running.
HALS_IOContext_Legacy_Impl::IOWorkLoop: could not establish a timeline after waiting 5000000 microseconds
```

and the plugin's `getZeroTimestampBlock` is never called during those five
seconds. AudioServerDriver does that itself (guest framework, image base
`0x249eae000`; offsets in the image):

* `-[ASDAudioDevice performStartIO]` (`0x5b2c`) copies each I/O block from its
  property — whose getter (`0x5fd4` for `getZeroTimestampBlock`) returns the
  very ivar being assigned — into that ivar and its unretained twin, starts
  the streams, sets `_running` and posts `'goin'`.
* `-[ASDAudioDevice performStopIO]` (`0x7ae8`) stops the streams, clears
  `_running`, then **releases every one of those blocks and stores nil in both
  ivars** (`0x7bc4`…`0x7d40`), and posts `'goin'`.
* `-[ASDStream stopStream]` (`0x7fb8`) does the same to the stream's blocks,
  `writeMixBlock` among them.

So a block set once at init survives exactly one start. The plugin now sets
them before every start: `installIOBlocks` at the top of the device's
`performStartIO`, `installMixBlock` before `[super startStream]`.

This is also what the "frozen seed" reading in
`virtualaudio_speaker_route_throws.md` had actually seen. The boot chime was
the first start and played; the ringtone after it was the second and timed
out. Moving the seed with every period did not fix that — a later run happened
to make its first start the tested one.

### The timestamp period must not change with the rate

Symptom, once starts worked: choppy playback, the HAL handing over about
45,700–46,000 frames a second on a 44100 device, and four times a second

```
HALS_IORawClock::Update: Re-anchoring IO timeline. Sample time is not consecutive,
HostTime is increasing, Ring buffer size: 12480.
```

12480 is the period the device published at init (48000 × 0.26 s). The rate
change to 44100 (`set nsrt`, answered by the device itself, see item 6
of the validation list below) had also moved `timestampPeriod` to 11466, but nothing makes the HAL
read that property again, so it kept checking that every zero timestamp
advanced by 12480 frames, found 11466, and re-anchored. The clock now keeps
the period's frame count for the life of the device and changes only how long
a period lasts (`VPClockSetRate`): 12480 frames take 0.26 s at 48000 and
0.283 s at 44100. Measured after: 44,086–44,094 frames/s in, zero re-anchors.

The seed follows the same rule the HAL states in that log family: it names the
timeline and moves only at an anchor (`performStartIO`, a rate change). Moved
with every period it produced `Re-anchoring IO timeline. Zero timestamp seed
changed` every 0.26 s.

### Nothing was queued ahead of the host

The virtio device plays what it is handed as it arrives, and the mix arrives
in real time: a period (4096 frames, 85 ms) is submitted when it fills, by a
timer that runs every 42 ms. With nothing queued ahead, any period later than
the one before it finished is a gap. Measured with the clock already fixed:
89 of 513 writes starved in one 44 s tone, 138 of 203 in the next.

The stream now queues `VPhoneVirtIOSoundLeadPeriods` periods of silence
(default 2, 171 ms) when the device starts, tops the queue back up when a
start finds the device still draining, and the device reports the lead plus
one period as `outputLatency` so video is presented against when the sound is
heard. Measured: 0 of 499 and 0 of 237 writes starved.

### Nothing left to set by hand

Both settings §4 and §5 asked for are now what the plugin does unasked:

* the device UID is `PuffinOutput` unless `VPhoneVirtIOSoundDeviceUID` names
  another;
* on an iPad guest (`hw.machine`), `ProductIDOverride` is set to 8010 in the
  `com.apple.audio.virtualaudio` domain from `halInitializeWithPluginHost:`
  when nothing stored names one. The plugin loads before VirtualAudio reads
  its defaults, and both are in audiomxd, so the in-process value is the one
  it reads; audiomxd's sandbox keeps the write off disk (`settings.get` still
  shows the domain empty), which is why it is repeated every launch. 8010
  rather than §4's 198 because 198's category map has no ringtone-preview
  entry (`virtualaudio_speaker_route_throws.md`, layer 1).

Verified on a guest with all four keys deleted and rebooted: VirtualAudio
initializes, the boot chime and a ringtone preview start I/O on
`PuffinOutput (VAD [vdef] AggDev N)`, no `not initialized yet`.

## Reveal and validation

1. Kernel side present: `strings` on the decompressed kernelcache shows the
   `AppleVirtIOSound` personality above.
2. Plugin loaded: `logs.syslog` for `audiomxd` shows
   `com.vphone.audio/virtiosound` lines `stream 0: 48000 Hz, 2 channels…` and
   `published 1 virtio sound device(s)`.
3. VirtualAudio initialized: `audiomxd` logs `Defaults key ProductIDOverride
   was defined to 8010`, `PlugIn initialized ? 2` / `VA Init Status: 0`, no
   `PRECONDITION FAILURE`, and no `VirtualAudio PlugIn is not initialized yet`
   when an app opens a session. The plugin supplies the override on an iPad
   guest (§6); `vpquery.log` says so when it had to.
4. Sound on the host: audible, and still audible after a stop. Beyond the
   plugin's own defaults (§6) the speaker route needs the VirtualAudio patches
   (`virtualaudio_speaker_route_throws.md`). In `vpquery.log`, every
   `performStartIO` is followed by a `stopStream` whose counters show `writes`
   in proportion to the seconds played, `0 starved`, and `in` at the nominal
   rate; `logs.syslog` for audiomxd shows no `Re-anchoring IO timeline` and no
   `could not establish a timeline`.
5. Hardware volume: the plugin answers the pspk route's volume queries with a
   real control set — dsrc selector ('ispk' "Speakers"), mute, volume — added
   from `halInitializeWithPluginHost:` after device init, before
   `addAudioDevice:`. Init-time `addControl:` fails the whole device
   activation (`HALS_PlugIn.cpp:162`); this lifecycle moment does not.
   Validated by staged isolation on ipad-pro-13 (2026-10-03): with
   `endpointTypeInfo` deleted, audiomxd restart, RingtonePreview playback,
   and a tone tap preview all left it absent — no more `Unspecified` rewrite
   — and `[volm/outp/0]` writes on the VAD succeed. Two constraints the
   controls themselves carry on iOS: construct them through the
   explicit-class initializers (`initWithValue:…andObjectClassID:` and the
   decibel twin), never the factories — the factories are state-dependent and
   returned the raw FourCharCode 'togl' as an `id`, crash-looping audiomxd —
   and never call `booleanValue` on the result (the getter is `value`;
   the selector does not exist and faults inside audiomxd). And the controls
   alone still do not give the device a mute property: iOS ASDAudioDevice's
   device-level dispatch has no 'mute' case at all, so
   `VPVirtIOSoundDevice` overrides the five ASD property methods and answers
   `kAudioDevicePropertyMute` from a shadow ivar, forwarding sets to the
   registered mute control (see the handoff in
   `virtualaudio_speaker_route_throws.md` for the disassembly).
6. Dual-rate (44100 ringtone previews): the device advertises
   `@[@44100, @48000]` and the 48 kHz stream carries a 44100 physical format;
   `setSamplingRate:`/`deviceChangedToSamplingRate:` move an atomic HAL rate
   under the mix block, which linearly resamples 44100→48000 onto the wire
   while the clock re-derives how long its period lasts (§6). Verified
   booting and answering at both nominal rates — and disproven as the ringtone gate: a 44100-nominal
   boot fails the tone tap exactly like a 48000 one. The gate is the
   RingtonePreview category itself; see the session-5 section of
   `virtualaudio_speaker_route_throws.md`.

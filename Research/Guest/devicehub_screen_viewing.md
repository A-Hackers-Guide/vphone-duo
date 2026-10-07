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

**Reverse-engineering result (2026-10-06):** the shared-cache force-kern patch was
reproduced against the local `24A446` cache. `_kern_SwapEnd` and the other
`_kern_Swap*` implementations load the connection's IOConnect port from
`[x0,#0x14]`; a zero value is the exact state that produces
`MACH_SEND_INVALID_DEST` on display 2. The public trampolines now use a
four-instruction dispatcher:

```text
cbz   x0, <original failure>
ldr   w16, [x0, #0x14]
cbnz  w16, _kern_Swap<Name>
b     _virt_Swap<Name>
```

`x16` is scratch, so the public ABI arguments survive both direct branches.
The patch discovers the public, `_kern_`, and `_virt_` siblings by symbol name,
keeps the original null-connection target, emits the branch and load bytes
through `ARM64Encoder`, and re-attests the full 16-byte write span. It upgrades
an older unconditional force-kern patch in place and is idempotent. On the
local 27.0.1 cache it classified 10 public entry points (including
`SwapBegin`, `SwapEnd`, and `SwapSetLayer`), left `SwapSignal` on its existing
virt implementation because it is not a thin trampoline, updated four code
signature slots, and passed the second-run no-op check.

**Deployment audit correction (2026-10-07):** prior statements that the
conditional patch had reached the guest were not proven. `applyDyldPatches`
skips an enabled patch when its identifier is already in the Guest receipt.
The guest undo log still contains 31 four-byte originals for force-kern,
whereas the new implementation writes ten 16-byte sites. A successful CFW
install and a receipt containing the identifier do not establish the new bytes.
Direct cache readback and an explicit revert/reapply are required next.

The host control socket's `screenshot` command calls the guest screenshot
API; it does not capture the VZ view. DeviceHub's saved screenshot also
shows the home screen, while its live panel is black. Neither screenshot
proves VZ scanout or live-stream success.

The attempted `0xcc` experiment replaced a raw byte sequence without
verifying the function instruction or the installed content. It is invalid
as an A/B test. Disassembly of the read-back guest hook currently confirms
`vpCurrentFeatures: mov x9,#0x8c; str x9,[x8]; ret`.

Actual evidence retained: the 26.6.2 DeviceHub live panel renders, the 27.0.1
panel is black, and a 60-second all-process capture reports
`FigVirtualDisplayProcessor Submits 0 / Encodes 0`. The SDK identifies
`e00002be` as `kIOReturnNoResources` and `e00002d5` as `kIOReturnBusy`.
Static IOMFB analysis shows a no-resources return when all 16 outstanding
surface-token slots are occupied; errors can also propagate from the
provider callback. It does not prove an empty resource table.

The proposed default-surface fallback was removed before guest deployment:
it overwrote the normal allocation block and failed to unwind the caller's
stack before tail-calling. Do not deploy `/tmp/vphone-bundle-fallback`.

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

## Verified reapplication and remaining display quality (2026-10-07)

The actual reapplication used the existing `devicehub-screen` worktree with
only the conditional IOMFB implementation and compare-branch encoder copied
in. Bundle `2.6.1-local.8aa77f2e` includes the original DeviceHub hook. With the
VM stopped, `fw set-patches --block dyld-boot-iomfb_force_kern` followed by
`cfw update-environment` reverted all 31 old four-byte sites. Restoring the
standard selection and updating with the new bundle wrote ten 16-byte sites,
re-attested four slots, and passed post-write decoding. The running guest's
undo log independently reports ten 16-byte originals. DeviceHub then showed
the home screen and subsequently Settings in its live panel.

The user reports large latency and content extending over the bezel corners.
These remain open. Guest stats now show 41–49 encodes/second rather than zero;
host receiver stats show about 54 fps, a 100 ms jitter buffer, and no transport
queue backlog in the sampled interval. One player sample was roughly 300 ms
behind its display-link timestamp. These are not an end-to-end latency test.

Changing the stopped guest from 1290x2796 to 1179x2556 was tested; the guest
confirmed 393x852 points at scale 3, but the rounded-corner overflow persisted.
The original dimensions are being restored. Matching the iPhone16 dimensions
alone is not a fix. The main VZ window still requires direct visual verification;
guest screenshots must not be used as evidence of host scanout.

Recovery and next discriminators: after restoring the 1290x2796 configuration,
vphoned timed out once although the VZ window visibly showed the home screen.
A controlled stop/start recovered the API, which now reports 430x932 points.
The VZ window was inspected directly through its installed bundle path;
scanout is confirmed, independently of the guest screenshot RPC.

The user measures roughly 1–3 seconds of lag, greater than the sampled
100 ms jitter buffer. Separate HID arrival from video delivery before
changing frame pacing. DeviceKit contains `loadFramebufferMaskAndChrome`,
`FramebufferMaskIdentifier`, and an explicit fallback to RoundedRectangle
when `showFramebufferMask` is true but a mask image is unavailable. Host logs
confirm chrome `com.apple.dt.devicekit.chrome.phone11` loads; they do not yet
prove which mask (if any) was selected. Missing/mismatched mask is a hypothesis,
not yet a verified cause or a reason to edit host Xcode binaries.

Mask lookup evidence: `/Library/Developer/DeviceKit/chrome_map.plist` maps
`iPhone17,3` to `phone9` and mask `A6AC96E7-C5D3-47A6-8967-A8B2D02F1C66`,
`iPhone17,1` to `phone11` and mask `4E5532ED-1470-47D1-BDF4-7AA90C26957A`.
There is no `iPhone99,11` entry. DeviceHub logs requested `phone11` for this
guest. `DeviceTreeGuestDevicePatches` explicitly preserves the virtual
`framebuffer-identifier` while copying real-board chrome properties. Inspect
the DDI display-info mask identifier next; the combination is suspicious but
not proof of the runtime fallback. Do not change the framebuffer identifier
in the device tree before tracing its other consumers.

Current DDI inputs for follow-up: `/tmp/dh-CoreDeviceUtilities` is the full
12,372,992-byte guest binary (`truncated:false`), version 642.16; its arm64e
slice is `/tmp/dh-CDU-arm64e`. Use thin-slice symbol addresses: fat-file `nm`
prints the arm64 slice first, whose addresses differ. The arm64e
`Display.framebufferMaskIdentifier` getter is at 0x33ea54; provider's default
fetch closure is at 0x343a00, async function pointer at 0x4064d0 resolves to
0x343b0c. `FramebufferIdentifier` literal is at 0x425a60. The DDI binary
imports MobileGestalt and has both ChromeIdentifier and FramebufferIdentifier
literals. A targeted xref analysis is running as exec session 95254 with output
`/tmp/dh-mask-xref.txt` (inspect current process state before waiting).

DDI arm64e xrefs completed: function 0x350f94 reads
`MGCopyAnswer("DisplayExtendedProperties", NULL)`, otherwise falls back to
`MGCopyAnswer("ChromeIdentifier", NULL)` at 0x351104 and
`MGCopyAnswer("FramebufferIdentifier", NULL)` at 0x3511a4.
`dtdeviceinfod` contains the DisplayInfo and DisplayInfoUpdates action
implementations, rather than dtremotedisplayd. An observational interpose
in the existing DeviceHub hook now logs only these three answers for
`dtdeviceinfod`, up to 12 queries, without modifying ownership or values.
The dedicated worktree includes its spawn target and negative suffix test;
`test-injection-environment` passes and the complete bundle builds.
Diagnostic bundle: `2.6.1-local.238f9151`; deployment log
`/tmp/dh-diag-update.log`, exec session 37312 (verify status before waiting).

Diagnostic readback from dtdeviceinfod PID 269 confirms:
`DisplayExtendedProperties = null`,
`ChromeIdentifier = com.apple.dt.devicekit.chrome.phone11`,
`FramebufferIdentifier = null`. The next build fills only that missing
FramebufferIdentifier in dtdeviceinfod when chrome is exactly phone11, using
Xcode's matching mask `4E5532ED-1470-47D1-BDF4-7AA90C26957A` and retaining the
CF result under the original Copy ownership contract. Existing answers and
other chrome types are unchanged. This is display metadata, not a change to
virtual hardware identity. Build session 88613, `/tmp/dh-mask-fix-build.log`;
visual validation and latency work remain pending.

**Mask fix verified (2026-10-07 09:02 local):** installed
`2.6.1-local.6a68184b`; dtdeviceinfod PID 272 now returns the phone11 mask UUID.
DeviceHub logged `Found FramebufferMaskIdentifier from displayInfo` with that
UUID at 09:01:54.327. Direct DeviceHub screenshots of both the home screen and
Settings show all four corners clipped inside the chrome. Resolution remains
1290x2796. This closes the corner-overflow issue, not the latency issue.
A Home button observation at roughly 564 ms after the UI action still showed
Settings; subsequent guest foreground query showed no verified app foreground.
It does not yet split HID delivery from capture delay. User follow-up about
remaining 1–3 second lag is pending.

## Cold-start timing audit (2026-10-07)

User reports current stream has no delay, but occasional 1–3 s lag starts at
boot. Healthy baseline player samples differ from last presentation by 3–20 ms.
First cold start settled at 14–16 ms. Second cold start's unlock request timed
out, although subsequent readback was unlocked. Its video session started
09:07:40; at 09:07:50 only six decode alarms had arrived over five seconds and
the previous presentation was 4.683 seconds old. By 09:07:55 it recovered to
5.8 ms and then 6–23 ms. This is a transient absence of frames, not evidence of
a persistently shifted playback clock. Compilation/tests were active during
this run, so repeat without host build load before attributing it to the guest.
Evidence: `/tmp/dh-timing-audit/cold2-host.txt` and `cold2-connect.txt`.

Seven updated real-cache conditional dispatcher tests pass, including dry-run,
idempotence, symbol discovery, and typed branch/port operands. A separate
Keystone parity/range test for compare branches also passes. Logs:
`/tmp/dh-conditional-tests-rerun.log`, `/tmp/dh-encoder-tests.log`.

User explicitly confirms cold2 was visibly stuttering; do not dismiss that
failure because cold3 was healthy. Full host log for 09:07:43–09:07:56 is
`/tmp/dh-timing-audit/cold2-fault-full.txt`. The player repeatedly reports
`alarmsSentForDecodeButNotDisplayedCount=16` at its threshold. Receiver reports
~56 fps, transport maxQueueDelay 0, and at 09:07:51.091 sends FIR with reason
`No video displayed timeout fail safe`. Playback recovers thereafter. This
supports investigating decoder/display scheduling or keyframe recovery, not
assuming no packets were being received or declaring build load the cause.

A temporary local app `com.vphone.devicehub.timingprobe` is installed on only
`dhtest-iphone27`. Source and IPA are under `/tmp/dh-timing-probe`. It displays
current guest epoch milliseconds at 30 Hz and a tap counter/color. It initially
crashed because iOS27 requires Scene lifecycle; the corrected SceneDelegate
build launches. At host capture interval 1791335680959–1791335681133 ms,
both the native VZ and DeviceHub screenshots showed 1791335680351. The common
host/guest offset must not be called DeviceHub latency. The comparative sample
shows no second-scale lag between displays in the healthy state. Remove the
probe after timing work; no production component depends on it.

### Cold4 and decoder-input refinement (2026-10-07 09:24 local)

Cold2 remains a user-confirmed failure. The full log narrows the observation:
VCPDec (1296x2816 HEVC) reports Input_fps=0 and Dec_fps=0 every second from
09:07:46 through 09:07:50, while the receiver's periodic report still records
packets and roughly 56 fps. The image queue's last enqueue is host time
452285.493, so a stale visible frame is established; decoder starvation is
observed, but capture failure versus packet assembly/reference recovery is
not yet separated. The threshold-16 warning also persists after presentation
recovers, so that warning alone is not a reliable failure detector.

Cold4 uses the same deployed bundle (6a68184b), with no build running during
the sample. Logs: `/tmp/dh-timing-audit/cold4-host.txt` and
`/tmp/dh-timing-audit/cold4-guest.json`. The 35-second guest sample contains
200 entries, steady ~30 fps encoding of the 30 Hz timing probe, no encode
drops, and ~9–11 ms encoder time. Host presentation samples remain ~15–18 ms
old. Direct VZ/DeviceHub screenshots both read 1791336178521 within host
capture interval 1791336178929–1791336179321. This is a healthy comparative
sample, not proof that intermittent startup lag is fixed. Other user VMs
remain running; host swap usage was about 17 GB, which is context rather than
a demonstrated cause.

The diagnostic probe now writes the runtime encoding of AVCVideoStream's
configure:error: to its own Documents/avc-types.txt: `B32@0:8@16^@24`.
This verifies BOOL/object/error-pointer shape only; no configuration key or
keyframe interval has been changed. Temporary probe remains installed for
further paired measurements and must be removed when diagnosis ends.

### Cold5–7, guest-side stall evidence (2026-10-07 09:33 local)

User confirms **VZ stayed fluid while DeviceHub stuttered in cold2**. This
is the key comparative observation; do not attribute cold2 to whole-guest
startup without contrary evidence. The temporary probe was rebuilt at 60 Hz.
Cold5 and cold6 paired screenshots show no seconds-scale difference. Cold5
has four host player samples (maximum presentation age 22.824 ms); cold6 has
seven (maximum 12.55 ms), no no-video timeout FIR. Cold5 guest encoding reaches
60 fps with no drops. These are bounded healthy runs, not a latency fix.

Repro script `/tmp/dh-cold-run.zsh` operates only on dhtest-iphone27, captures
host logs, polls actual stopped state, starts the VM, collects guest logs,
then unlocks/launches the probe. Summary script `/tmp/dh-timing-summary.rb`
identifies the latest new player by its tick-zero record. Cold7 unlock timed
out; the script exited and stopped host streaming. The already-running guest
log finished normally. No duplicate VM restart was attempted. Subsequent
unlock and probe launch succeeded (PID 374). Host history recovered the
missing interval into `/tmp/dh-timing-audit/cold7-full-host.txt`.

Cold7 is not yet the same confirmed failure as cold2: an early screenshot
showed VZ still at the boot logo (8 fps), DeviceHub connecting, and the probe
had not launched. Nevertheless paired logs expose a concrete guest-side
anomaly. Guest AVConference encoder/FigVirtualDisplayProcessor reports stop
between 01:31:28Z and 01:31:45Z, while VTP health messages continue. At
01:31:45Z, 22 VTP_Send calls fail with errno 55 (ENOBUFS, verified against
Xcode SDK sys/errno.h), and the encoder reports 124.65 ms encode time. Host
HEVC decoder input drops to 0–4 fps for much of that interval, with player
presentation ages up to ~6.6 seconds. This is evidence of a guest capture /
encoder / send-path interruption; ENOBUFS may be a consequence of the burst
on recovery, not the initiating cause. Detailed timeline:
`/tmp/dh-timing-audit/cold7-encoder-timeline.txt`.

Next investigate the guest encoder/capture thread during a reproduced stall,
including scheduling and queue waits, before altering periodic keyframes.
The keyframe configuration path was statically traced in pristine 24A446:
AVCVideoStreamConfig.dictionary emits vcMediaStreamKeyFrameInterval;
VCVideoStreamConfig.applyVideoStreamClientDictionary reads it;
VCVideoTransmitterDefault.initWithConfig passes it into its transmitter
configuration. A different VT stream-transmitter path maps it to
MaxKeyFrameIntervalDuration, but that alone does not establish semantics of
the active HEVC path. No production keyframe/LTRP configuration was changed.
Evidence disassemblies are `/tmp/dh-avc-*.txt`; no IDA MCP was available, so
local ipsw cache disassembly was used. Do not paste raw disassembly in chat.

### Thread profiling established (2026-10-07 09:44 local)

Used the existing safe guest profiling procedure in
`Research/Guest/display_refresh_rate.md`. Never run a host VM-process sample
at the same time as guest spindump. A temporary launchd job under /var/tmp
runs /usr/sbin/spindump; after each finished capture it is unloaded and
verified not loaded. No production hooks or configuration changed.

Healthy baseline: 8 seconds, `/tmp/dh-healthy-spindump.txt` (5,643,448 bytes,
readback not truncated). avconferenced encoder thread is normally mostly
waiting for work (167/240 samples), with 51/240 samples in frame checksum
pixel transfer through VideoToolbox / IOSurfaceAccelerator. This is normal
baseline evidence, not proof that this path causes the intermittent stall.
Symbolicated excerpt: `/tmp/dh-healthy-avc-symbolicated.txt`.

Cold8: 35-second whole-guest capture, `/tmp/dh-cold8-spindump.txt`
(16,807,571 bytes, readback not truncated), six host player health samples,
maximum presentation age 6.344 ms, no no-video timeout FIR. Probe initially
launched verified PID 378, but the later screenshot showed Home, so this is
not a verified full-duration continuous-probe test. No new TimingProbe crash
report appeared (only the initial 09:12 lifecycle crashes exist).

Cold9 validated a much cheaper targeted capture:
`spindump avconferenced 40 20 -onlyTarget -wait -noBinary -file <report>`.
It exits 0, and the text report is 140,796 bytes, containing 955 samples of
avconferenced. Guest encoding stayed around 58–60 fps; seven host samples
have maximum presentation age 5.656 ms, no timeout FIR. Report:
`/tmp/dh-cold9-avc-symbolicated.txt`. Use this targeted recipe next time so
report transfer and unrelated process sampling do not dominate diagnosis.
The temporary com.vphone.devicehub.spindump job is unloaded.

Symbolication uses pristine 24A446's per-image symbols with runtime cache
base 0x180000000 (zero slide here), via `/tmp/dh-symbolicate.rb`; symbol dumps
are `/tmp/dh-{avc,VideoToolbox,CoreMedia,VideoProcessing,IOSurfaceAccelerator}-symbols.txt`.
Do not reuse zero slide for another guest without checking its report header.
Host currently has 64 GiB RAM, 18 logical CPUs; memory_pressure reported 70%
free, so its ~15 GiB historical swap allocation is not proof of current
memory pressure. Cold7 CoreDevice tunnel history shows old connection
teardown before the new video stream, no established transport root cause.

Settings real-content check: direct guest input.swipe from (215,800) to
(215,300) moved the list, and direct VZ/DeviceHub screenshots showed the same
result with correct masks. This is functional display evidence, not a precise
latency measurement. CUA scroll/drag in DeviceHub itself did not visibly move
the list, so DeviceHub-input verification remains separate and inconclusive;
do not claim that end-to-end interaction passed from the direct guest swipe.
Cold2 remains the user-confirmed VZ-fluid / DeviceHub-stuttering failure;
no current evidence supports closing the intermittent-lag issue.

### Cold10–12 and bounded load comparison (2026-10-07 09:53 local)

Cold10: nine post-start host samples, maximum presentation age 13.658 ms;
guest encoding 59–60 fps; direct VZ and DeviceHub timestamp captures differed
by 34 ms in a 423 ms capture window. Targeted spindump readback was 143,528
bytes, not truncated. No matching fault captured.

Cold11 deliberately reran the same real-cache patch tests that were active
during cold2 (not an arbitrary CPU stressor). All seven tests passed again:
`/tmp/dh-timing-audit/cold11-load-tests.log`. The VM's vphoned did not answer
within 90 seconds and a subsequent ping still said guest not connected. Thus
no guest profiler was loaded in this round. The guest UI itself was alive:
native HID swipe dismissed Lock Screen and both VZ/DeviceHub displayed Home.
Host video samples reached a maximum presentation age of 239.904 ms, not the
cold2 multi-second fault. The guest console logged APFS transaction waits of
~1–1.7 seconds. This cannot establish a cause for cold2. After both test and
startup command were terminal and control stayed offline, cold12 restarted
the same VM without test load; vphoned connected in four seconds.

Cold12: nine new-stream samples, maximum presentation age 10.025 ms, guest
encoding ~58–61 fps; 35-second backboardd capture has 73 entries, not
truncated, and no swap_end / get_wireless_surface_options / invalid-dest
match. Targeted profiling ended and its temporary job was unloaded. Latest
report JSON: `/tmp/dh-cold12-spindump.json`.

The summary parser was corrected to discard all health lines preceding the
last tick-zero initialization, not merely match the player pointer. The
allocator reused the cold11 player address in cold12; a 4-second presentation
age from the old closing stream otherwise falsely contaminated the new run.
Recomputed cold4–10 figures are unchanged. Do not use pointer identity alone
across a stream restart. Health-age samples still do not measure full input
latency or prove the intermittent problem fixed.

Code comments now describe the current conditional dispatcher, its actual
real-cache tests, and the third DeviceHubFix injection target (dtdeviceinfod).
Removed stale claims that Python is executed or current output must match the
old unconditional patch digest. These are comment-only edits. Awaiting the
user's current visual observation before repeating the same cold-start matrix.

Startup-readiness hypothesis checked against current DDI arm64e:
MediaStreamSupportedFeatures.current at 0x392f38 calls CurrentDevice.init at
0x329850 and returns no features if device identity cannot be constructed.
The initializer's required optional inputs are versionNumber, buildUpdate,
and deviceType (0x329c88, 0x32a284, 0x32aacc). This does not establish a
SpringBoard/compositor-ready gate, so do not add an arbitrary startup delay
or claim the support-info interpose skipped such a gate. Disassemblies:
`/tmp/dh-cdu-current-features.txt`, `/tmp/dh-cdu-currentdevice-init.txt`.

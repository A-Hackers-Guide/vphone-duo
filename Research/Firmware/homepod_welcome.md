# HomePod mini first-boot welcome

The 2026-10-23 Sound Glow tests on 27.2 exposed an AirPlay interaction absent
from the original speech-only tests: the nonmixing auxiliary Playback session
made the Music sender switch back to the Mac. The adapter now uses AVFAudio's
MixWithOthers|DuckOthers category options and NotifyOthersOnDeactivation. It
retains the separate native session and synthesis completion lifetime; the
shared session and microphone route remain untouched. Local lifetime/error
tests and the bundle pass; live AirPlay/Siri handoff validation is recorded in
[Sound Glow](homepod_sound_glow.md).

The guest policies, SoundBoard welcome coordinator, isolated Siri playback
adapter and durable once state are implemented. Local tests pass. Live tests on
27.0 (24J361) confirm audible native Siri speech, the exact automatic welcome
sentence, tone 1 and both native animations. The first live run exposed an
Identify ownership cleanup error, corrected and validated on a fresh-identity
clone. The original guest retains its claim without replay after update, cold
boot or SoundBoard restart; direct Siri speech and tones still work afterward.

## Patch policies

Both patches are optional, apply to 27.x and are admitted only for HomePod guests.
Only the `homepod-mini` preset selects them by default; Standard, Experimental
and both Apple TV presets leave them off. Built-in selections and shipped
preset plists agree.

| Patch | Generated guest policy | Required selections |
| --- | --- | --- |
| `system-homepod-exp-siri_speech` | `/usr/share/vphone/HomePodSiriSpeech.plist` | vphoned, HomePod top cap, virtio sound |
| `system-homepod-exp-welcome` | `/usr/share/vphone/HomePodWelcome.plist` | Those three, local setup completion, native Siri speech |

The exact prerequisites are `system-vphoned-boot-install`,
`system-homepod-exp-top_cap`, `system-virtiosound-cfw-hal_plugin`, and for the
welcome also `system-homepod-exp-setup_bypass` and `system-homepod-exp-siri_speech`.
The installer checks dependencies before guest filesystem writes, then generates
root-owned, mode `0644` binary plists containing `Enabled=true`. Opt-out removes
only the selected policy and preserves guest Data state. Speech can be selected
without welcome or setup bypass; welcome cannot keep a missing prerequisite.

## Guest runtime

The existing HomePodDisplay dylib is injected only into SoundBoard by the top-cap
patch. The Siri adapter validates native method ABIs and installs only while its
policy is enabled. The welcome lifecycle hook installs only after that succeeds.
After Apple's `_applicationsModuleInitComplete` returns, a main-queue timer waits
for `SBSetupController.deviceNeedsSetup=false`, completed native display startup,
`DrawingEnabled=true`, enabled Siri and Siri UI, and an idle Siri session. It
leaves other foreground activities and active media alone; idle `NowPlayingCap`
is a normal foreground activity and does not block the welcome. It never forces
SoundBoard's singleton into existence from the dylib constructor.

After a durable claim the coordinator activates the existing Identify activity
through `setLocalSessionActive:YES`, then plays native tone 1 through
`SBUITonePlaybackManager play:completion:`. Tone 1 resolves to
`HomePodReadyToSetUp-b238.m4a`; the debug selector is `playTone:`.
The native manager takes UInt32 (`v28@0:8I16@?20`), not UInt64. A direct donor
cache audit caught the initial mock/guard mismatch before installation; the
regression harness now compares its tone mock against that independent encoding
and verifies that the old UInt64 shape is rejected.
`HPACoordinatedSession.setActive:` is an error/no-op, so it must not be used.
Identify's `launchWithOptions:` would also play tone 6, so the welcome does not
use that entry point. Apple's Identify renderer supplies the animation;
`setLocalSessionActive:NO` releases it when the tone finishes or fails. The
coordinated setter clears ownership, calls Identify's `endLocalSessionActivity`
cleanup and dismisses the foreground activity. Calling the subclass cleanup
directly leaves Identify active and lets it resurface after Siri finishes.

After successful tone completion and a 650 ms pause, the coordinator rechecks
policy and Siri idleness, then calls the native Siri manager with exactly:

> Hi, I'm Siri. It sure is great to be running in a virtual machine!

The normal type 13 SiriVOX session drives HPASiri's animated display state. The
speech adapter supplies a real active auxiliary playback-session ID so SiriVOX
can use its existing external-session path. The request retains the auxiliary
manager through synthesis finalization, then deactivates/releases it exactly
once and forwards the native NSError. Disabling policy restores original
`say:completion:` dispatch. Neither AVAudioSession's shared instance nor global
product identity, audio routing or microphone capability flags are changed.
There is no host playback timer, generated LED replay or new LaunchDaemon.

## Once-only state

The first eligible ready boot exclusively creates and fsyncs `Claim.plist` under
`/var/mobile/Library/Application Support/vphone/HomePodWelcome/<UniqueDeviceID>`
before its first audiovisual side effect. Identity comes from a read-only
MobileGestalt query. Keying by guest identity lets a clone of an already-booted
template receive its own welcome. The immutable claim survives SoundBoard
restarts, reboots and bundle/environment updates. Neither a new OS nor a new
bundle version resets it. Waiting for readiness leaves it unconsumed.

This provides at-most-once behavior. A crash after the durable claim may leave
the sequence incomplete; it must not replay an already-started welcome. Empty,
partial and malformed existing claims also prevent replay. I/O or symlink
failures fail before playback. New directory entries, the claim and its
containing directory are synced before playback can begin.

`Status.plist` is replaced separately and records `TonePlaying`, `ToneFinished`,
`SpeechRequested`, `SpeechFinalized`, cancellation, timeouts or native failures.
Error domain/code/description are retained. `say:completion:` reaches SiriVOX's
synthesis finalizer, which supplies the result's error. The API omits the result
type, including cancellation, so a nil error is recorded as finalized rather
than asserted as audible speech. The debug XPC endpoint acknowledges submission
without exposing this completion. Keeping the claim through opt-out prevents
re-enabling the patch from replaying the welcome.

## Native speech evidence

The 27.0 24J361 donor is the authority. Extracted `SoundBoardFramework` SHA-256:
`a352a2ba4025e714ca8b7208490991d821f63387aeb5268c7937974029246749`;
`SiriVOX` SHA-256:
`84726d96209afc6f1bb9272e18c7fcd9a0e043e7589cb0b87b2b8494d7969dd9`.
Addresses below identify these artifacts, never patch offsets.

- `SBSiriManager say:completion:` (`0x1a6c0297c`) builds a normal type 13
  `SVXSystemEvent` containing an `SVXSpeechSynthesisRequest` (priority 2,
  speakable text, options 0), then activates it through SiriVOX.
- With a zero event audioSessionID, SiriVOX forces audio-session activation
  (options 0, reason 3). The installed guest fails here with AF 221, underlying
  OSStatus -11795, before `sirittsd` receives synthesis work.
- CoreSpeech reports `No input routes. AQ engine couldnt find routes since
  VSPD is not present!`, a nil record route and failed `prepareRecordForStream`.
  Native recording setup requests a physical 14-channel HomePod path. A missing
  voice asset has not been demonstrated.
- A nonzero event audioSessionID follows the existing external-session branch
  and forwards that real session ID to synthesis. The adapter uses
  `SBAudioSessionConfiguration initWithCategory:categoryOptions:`,
  `SBAudioSessionManager auxiliaryAudioSessionManagerWithConfiguration:name:`,
  `activateAndReturnError:` and the returned AVAudioSession's UInt32
  `opaqueSessionID`. It does not invent a bypass ID or relabel a microphone port.
- The early nil callback in SiriVOX's speech-start block is its
  `postActivationHandler`, distinct from the original caller completion. The
  latter flows through synthesis finalization and `SVXSpeechSynthesisResult.error`.
  Earcon `didStopSoundWithID:` callbacks are not utterance-completion signals.

Focused disassembly, donor method encodings, REA snapshots and live diagnostics
are retained locally under `.build/homepod-welcome-research/`. They are diagnostic
artifacts; the shipped guest runtime uses framework APIs and runtime metadata.

### External-session animation audit (2026-10-23)

Static native evidence supports leaving Apple's display lifecycle in control:

- SiriVOX's external-session preparation block (`0x1a68f4a88`) sets its internal
  lifecycle active and calls
  `session:didBecomeActiveWithActivationContext:activityUUID:turnID:`. This is
  distinct from the public Siri UI state enum. REA evidence:
  `ev_a7edd03019e050ef20daec94b05d8b0bb2ce04c206916e8a4cd9dedb406ed2f5`.
- `HPASiri siriSessionService:didChangeStateFrom:to:` (`0x1a6b7aaa4`) updates its
  renderer state, then activates its local coordinated session for listening,
  thinking or presenting (2 through 4), except for native alarm/skip cases.
  Type 13 is not the type-12 bypass. This route does not require the separate
  `audioSessionDidBecomeActive` flag used by `_updateSessionsActive`. REA evidence:
  `ev_c9b20b00458acfa58b52242028a8f32c38c556701a8f5304d7cb18d6caee99b3`.
- Native `drawSurface` (`0x1a6bc7d5c`) sends the current state to
  `renderTransitionToSiriUIState:siriUIRenderState:` when the legacy renderer is
  selected and `_shouldAnimate` permits it; SAE uses the corresponding native
  animation/descriptor route. REA evidence:
  `ev_b82d1f359c74898ffe1695552a1df6bcb2256696fc5f3e3d44f75b1bf7d9b261`.

The direct donor-cache probe resolves those shared selector stubs and verifies
the welcome's native readiness signatures, including the UInt32 tone argument.
Its source/results are `audit-welcome-native.swift` and
`welcome-native-abi-audit.txt` in the local research folder. Numeric branches are
checked against decoded instructions: Hopper's pseudocode loses the unsigned
subtract/range test in the Siri state callback and must not be read literally.
Snapshots are `soundboard-animation-audit-rea.json` and
`sirivox-external-animation-audit-rea.json`. These establish native control flow,
not actual frame delivery, speech metering or audibility in the installed guest.

## Verification

Catalogue/resolution tests pass (43 tests), covering version/preset selection,
TV rejection, both policy targets, missing dependencies and independent opt-out.
The complete `VPhone` Debug bundle builds successfully and passes bundle
admission. Xcode's connector lists the owning test scheme but omits the aggregate
`VPhone` scheme, so the catalogue tests ran through Xcode MCP and the finished
bundle used the repository's documented `xcodebuild` command with the selected
`/Applications/Xcode.app` toolchain. The built CLI also emits the updated patch
catalogue successfully.
The standalone harnesses run with:

```zsh
make -C VPhoneGuestComponents test-homepod-welcome test-homepod-siri-speech test-homepod-display
```

They cover native readiness ordering, idle NowPlayingCap versus active media,
exact phrase/tone ordering, failures, cancellation, changed ABIs, restart/no
replay, 32 concurrent claims, nested directory durability, malformed/partial
claims, symlinks, real write failures, native speech event fields, auxiliary
session lifetime and cleanup, duplicate completion and original dispatch when
disabled. The display harness checks the existing MiniDisplay identity adapter.
Mock tests establish control flow and ABI handling, not audible synthesis.

### Live validation (2026-10-23)

Installed through Launchpad with `--keep-default`; the final host and guest
bundle bound to `homepod-mini` is `2.11.0-local.3f1d474e`. Other machines and the
library default were preserved. The final complete bundle build passed admission
and the four standalone state/welcome/speech/display harnesses passed. The
original virtual product token and the existing audio-only ProductIDOverride
remain unchanged.

Before enabling welcome, the speech policy was tested alone and the old
`HomePodBuddyConnection` research override was reset through the native debug
interface followed by a normal SoundBoard restart. The owner heard the exact
full sentence. Synchronized native logs establish a five-second utterance,
SiriHeadlessService `#Success #SpeechRequest`, sirittsd playback start/finish,
SoundBoard presenting-to-idle, nil final NSError and auxiliary-session
activation/deactivation. Native colorful top-cap generations advanced through
1056, 1166 and 1244, then returned to black at 1322/1336.

Enabling welcome produced native tone 1 and Identify at 09:38:45 UTC, tone
completion at 09:38:50, speech request at 09:38:51 and speech finalization at
09:38:56. The owner confirmed tone, the full sentence and both animations.
This run exposed Identify remaining active after the subclass cleanup callback.
The fix calls `setLocalSessionActive:NO`, the native ownership setter that
clears the flag, invokes `endLocalSessionActivity` and dismisses the activity.
The mock now models that distinction rather than clearing ownership in the
callback. Donor REA evidence:
`ev_ca49a2aa400858202bf60981f5512d8c5bf4da3583865995f66d8f29fa4067f1`
(setter) and
`ev_7199672608d79af3adaceccbac5c735e3968d6934ec5dbbd7e36f415f4299774`
(Identify callback), retained in `soundboard-identify-cleanup-rea.json`.

A temporary APFS clone with `--new-identity` verified the corrected whole sequence
without resetting the original claim. The clone retained the copied identity's
claim and created a second claim for its own identity. At 09:43:43 it played tone
1 with Identify; at 09:43:48 Identify went inactive and the activity stack
returned to idle before speech began. At 09:43:53 Siri finished, its auxiliary
session deactivated and Status became `SpeechFinalized`. Diagnostics then showed
no foreground activity, an empty stack, `IdentifyRunning=false` and Siri idle.
The temporary clone was stopped and removed after saving its evidence.

The original was updated to the final bundle and cold-booted. Its Claim and
Status bytes remained exactly unchanged (claim 09:38:45, finalization 09:38:56).
A complete, untruncated boot capture contained no welcome tone or speech. A
normal SoundBoard restart then produced another complete capture with the
speech adapter installed, no welcome playback and an empty idle activity stack.
The marker was never removed or rewritten to replay a test.

After that restart, direct `siriSay:` was retested on the final original VM:
09:47:16 presenting, 09:47:21 idle, auxiliary session deactivated, final error
nil. Colorful frame generations 309/405/496 became black at 625. Ordinary tone 1
then played at 09:47:27 and completed normally at 09:47:32. The owner confirmed
both audible outputs and the display's return to idle. The VM remains running
with the default `homepod-mini` selection and its original claim intact.

Raw live RPC results, synchronized logs, frame samples, claim/status copies and
build logs are local diagnostics in `.build/homepod-welcome-research/`, not
shipped runtime dependencies. The welcome is initiated and coordinated wholly
inside SoundBoard; the host RPCs above are verification only.

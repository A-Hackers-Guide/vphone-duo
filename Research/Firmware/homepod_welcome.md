# HomePod mini first-boot welcome

The guest policies, SoundBoard welcome coordinator, isolated Siri playback
adapter and durable once state are implemented. Local tests pass. No updated
bundle has been installed; audible Siri speech and the full welcome still need
live validation.

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
`endLocalSessionActivity` releases it when the tone finishes or fails.

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

## Verification and remaining live checks

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

Live proof must establish exactly one tone/flourish sequence, the exact spoken
sentence, native Siri animation, completion ordering and no replay after cold
boot. It must also repeat direct debug `siriSay:` and verify display and ordinary
tone playback with the original product token intact. Bundle installation and
these end-to-end checks are deferred until the user is available to authorize
updates. The prior installed audio/display build remains in place.

### Live validation order when authorization is available

1. Install the candidate with `bundle install-local <path> --keep-default`.
   Use its returned version when rebinding `homepod-mini`; preserve the library
   default and other machines. The last read-only inventory still has this VM
   running host/guest bundle `2.11.0-local.40cd1d45`.
2. Inspect the machine's current patch selection. For an initial speech-only
   comparison, block welcome while keeping native Siri speech selected, then
   stop/rebind with `vm set-bundle ... --update-environment`. Do not weaken any
   boot-volume protections or edit the root-owned installed bundle manually.
3. Clear the earlier research-only Buddy debug override before the comparison.
   The existing VM retained `HomePodBuddyConnection` with a simulated
   `siriThinking` activity; this is absent from the default template. Reset that
   default through SoundBoard's native debug interface and restart SoundBoard
   normally (or apply it before the planned VM reboot). Do not replace it with
   another debug override or an LED replay to make the welcome visible.
4. On the speech-only boot, capture SoundBoard/SiriHeadlessService/sirittsd logs,
   native activity diagnostics and top-cap frames while issuing `siriSay:` with
   the exact sentence. Confirm audible speech, presenting-to-idle rendering,
   native finalization, isolated-session cleanup and continued ordinary tone
   output. A submitted debug RPC alone is not a pass.
5. Re-enable welcome, update the guest environment through Launchpad and boot
   with the listener ready. Verify native tone 1 and Identify animation first,
   then the short pause, exact Siri sentence and its native speech animation.
   Inspect the guest's identity-scoped claim/status after playback.
6. Cold boot again and restart SoundBoard: the welcome must not repeat. Verify
   that standalone `siriSay:` remains usable and display frames still arrive.
   Retain the consumption marker; do not add a production reset/replay trigger.

These are planned checks, not completed live results. Administrator authorization
is needed for bundle installation and guest-environment deployment; it has not
been requested while the user is unavailable.

# iOS 27 capture sources: the microphone goes with the camera

On an iPhone guest (`mictest-iphone`, iPhone99,11, iOS 27.0 24A435) Voice
Memos' Record failed before any audio I/O, while the same build of the sound
plugin records on an iPad guest (iPadOS 26.6.2). The audio route was fine
(`virtio_sound_microphone.md` §6). This note is the capture-stack half:
which code decides the capture source list, why it ends empty on a VM, and
what the hook in `libvcamcaptured` does about it.

Sources: CMCapture, AVFCapture and the VoiceMemos framework extracted from
the 24A435 iPhone17,3 restore image's shared cache (`ipsw extract --dyld`,
symbols from its `.symbols` file; addresses below are that cache's), the
guest's own `VoiceMemos.app/VoiceMemos` and
`CMCapture.framework/D47/AVCaptureSession.plist`, the guest's syslog, and
`/var/mobile/Media/SimulatedCamera/vcamcaptured.log`.

## 1. What Voice Memos asks for

iOS 27's Voice Memos records through `VoiceMemos.CaptureSessionRecorder`, an
`AVCaptureSession` with an audio device input and an
`AVCaptureMovieFileOutput` / `AVCaptureAudioDataOutput` (the app's strings:
`defaultDeviceWithDeviceType:mediaType:position:`,
`So24AVCaptureMovieFileOutputC`, `So24AVCaptureAudioDataOutputC`). Its error
enum, from the app's Swift metadata (`ipsw swift-dump`):

```
enum VoiceMemos.CaptureSessionRecorder.CaptureSessionRecorderError {
    case failedToCreateAudioDeviceInput(Error)   // code 0
    case failedToCreateAudioDevice                // code 1
    case cantAddAudioDeviceInput
    case cantAddAudioFileOutput
    case cantAddSampleOutput
    case multichannelAudioModeNotSupported
}
```

Swift numbers payload cases first, then the rest in declaration order, so
`CaptureSessionRecorderError Code=1` is `failedToCreateAudioDevice`: the
lookup of the microphone `AVCaptureDevice` returned nil. (The numbering rule is
the compiler's, not read from the app's code.)

The iPad guest's Voice Memos (26.6.2) records without `AVCaptureSession`, which
is why it never met this.

## 2. Where the capture sources come from

AVFoundation clients get their devices from cameracaptured's source server.
In iOS 27 (and 26.6, whose cache has the same strings and the same exported
functions) the built-in sources are made by
`+[FigCaptureSourceBackingsProvider sharedCaptureSourceBackingsProvider]`
(0x1b0447838), the function that logs as `cs_getBackingsForBuiltInCameras`:

1. Read `CaptureSourceInfo` from the preferences domain
   `com.apple.cameracapture.volatile`. If present and still valid
   (`csu_createBackingsFromCaptureSourceInfoDict` compares
   `DependentUserDefaults`, `FileModificationDate`, `InterpreterBuildDate`,
   `DeviceModel`, `ExperimentsEnabled`), make the backings from it.
2. Otherwise ("is empty, will repopulate") call
   `csu_createSourceInfoDictionariesFromAVCaptureSessionPlistForCaptureDeviceIDs`
   (0x1b07affe0) for `@[BWFigCaptureDeviceID_Default]`. For each device ID it
   asks `-[BWFigCaptureDeviceVendor copyDeviceForPublishingWithID:error:]`
   for the device. Only when that succeeds (0x1b07b0564 `cbnz x0`) does it
   load the model's `AVCaptureSession.plist` and call
   `FigCaptureCreateSourceInfoArrayFromDeviceAndModelSpecificPlist(device,
   plist, …)`. A failed copy is logged (`Error copying device %@ (%d)`), the
   error kept, and the device skipped.
3. A non-zero error makes the caller bail: `Error %d while creating
   FigCaptureDevice. Wiping com.apple.cameracapture.volatile…`,
   `Fig assert: "err == 0 " at bail (FigCaptureSourceBackingsProvider.m:1083)`.
   No provider is stored; the method returns nil, and the server reports
   `0 total in-memory backings`.

`FigCaptureCreateSourceInfoArrayFromDeviceAndModelSpecificPlist` (exported,
0x1b07a9ecc) is where the microphone is described. It walks the plist's
`AVCaptureDevices`, and the entry with `mediaType` `"soun"` and `uniqueName`
`"Microphone"` becomes a source info dictionary with `MediaType` `'soun'`,
`NonLocalizedName` "Microphone", `UniqueID`/`ModelID`
`kFigCaptureAudioSourceUniqueID_Microphone`, `PrefersDecoupledIO` and the
per-preset audio settings. That branch does not use the device; the camera
entries do (`csu_addSecureMetadataKeysToDeviceDict`,
`-[FigCaptureSourceStreamsContainer initWithDeviceType:…device:…]` inside
`csu_createVideoCaptureSourceInfoForCaptureDeviceFromModelSpecificPlist`).
`-[FigCaptureSourceBackingsProvider _addBackingsForSourceInfoDictionaries:]`
sets `_hasMicSource` when it meets the `'soun'` dictionary.

So the microphone's source is built in the same call as the cameras', and that
call is reached only after the camera device exists.

## 3. Why the camera device does not exist on a VM

`-[BWFigCaptureDeviceVendor _createDevice:reason:clientPID:figCaptureDevice:]`
logs `Cannot create device without create function!`: the vendor was made
with `initWithDefaultDeviceCreateFunction:` and no function. The function
comes from the ISP capture plugin (`/System/Library/MediaCapture/H16ISP.mediacapture`
and its siblings are the paths CMCapture knows); the guest's
`/System/Library/MediaCapture` is empty. The copy fails with -12786, and §2
step 3 follows.

Verified on the guest: `vcamcaptured.log` with a logging wrapper around the
provider method shows the original returning nil at the daemon's first source
query, and the guest syslog shows the -12786 chain quoted in
`virtio_sound_microphone.md` §6.

## 4. The virtual camera does not change this

`libvcamcaptured` is loaded into cameracaptured by SystemHook whether or not
the host streams a camera; host streaming only feeds the shared frame. Its
camera source is installed by appending a synthetic source to `_sSourceList`,
the iOS 26.x source-server list, and on iOS 27 that fails before anything is
appended:

```
filter-chain scan: pc=0x0 si_fn=0x0 prewarm_fn=0x0
init-statics block-invoke lookup failed
data global resolve failed: _sSourceList not located
```

Even where it works, it appends one camera source and hands out its synthetic
device only for its own device ID (`copyDeviceWithID:forClient:…`), never for
`copyDeviceForPublishingWithID:` with `Default`. Nothing in it gives the vendor
a create function or touches the backings provider, so switching the virtual
camera on cannot bring the microphone back. The iOS 27 virtual camera is a
separate open item.

## 5. The fix: a microphone-only provider

`VPhoneGuestComponents/VCamCaptured/Microphone/VCamMicrophoneSource.m`,
installed from the dylib's constructor (not with the camera hooks, which wait
3 s), wraps `+sharedCaptureSourceBackingsProvider` with
`method_setImplementation`:

* The original runs first. A provider it returns is passed through unchanged.
* When it returns nil, the wrapper builds a provider once and returns it from
  then on:
  1. Plist: `FigCaptureSourcePlistCreateAndPreprocessForModelSpecificName`
     (exported) for `FigCaptureGetModelSpecificName()`. On the iPhone guest
     that name is `VPHONE600`, which has no folder; CMCapture ships one per
     product in the restore image (`D47/AVCaptureSession.plist` for
     iPhone17,3) next to `iOS/` (external cameras). The wrapper then tries
     each product folder that has an `AVCaptureSession.plist` and takes the
     first with a `"soun"` device.
  2. That plist with `AVCaptureDevices` reduced to its `"soun"` entries goes
     to `FigCaptureCreateSourceInfoArrayFromDeviceAndModelSpecificPlist` with
     a NULL device, a non-NULL date (it is stored into a dictionary
     unconditionally) and `persist` false, so nothing is written to
     `com.apple.cameracapture.volatile`.
  3. `-[FigCaptureSourceBackingsProvider initWithSourceInfoDictionaries:commonSettings:]`
     with the result.

The function's signature, read from its two call sites and its body:
`void (device, CFDictionaryRef plist, CFDateRef date, Boolean persist,
CFArrayRef *outSources /* +1 */, CFDictionaryRef *outCommonSettings /* +1 */)`.

Seeding `CaptureSourceInfo` in the volatile domain instead was rejected: the
cached dictionary is checked against five values (§2 step 1), the
provider's `+initialize` writes the same key (0x1b098b7d0), and every failed
build wipes the domain.

No firmware byte changes; the dylib already ships in the guest environment.

## 6. Validation

Done on `mictest-iphone` with the first build of the wrapper (bundle
`2.4.0-local.9c275f8f`, which tried the guest's own model name only):

```
mic source: wrapped +[FigCaptureSourceBackingsProvider sharedCaptureSourceBackingsProvider] (orig imp=0x2e520001b0447838)
mic source: no AVCaptureSession.plist for model VPHONE600
```

The second line is only reached when the original returned nil, so the
daemon's own provider is nil at its first source query, as §2 reads. It also
showed that the guest's model has no plist, which the product-folder fallback
in §5 answers.

With the fallback (bundle `2.4.0-local.473d5071`, deployed by the
coordinating session):

```
mic source: no AVCaptureSession.plist for model VPHONE600
mic source: model D47, 1 source info(s), provider 0x658ca0f00, hasMicSource=1
mic source: daemon built no provider; serving the microphone-only one
```

Voice Memos then gets its device and runs the session: `-[AVCaptureSession
addInput:]: <AVCaptureDeviceInput [iPhone Microphone]>`, an
`AVCaptureMovieFileOutput` and an `AVCaptureAudioDataOutput`, and
cameracaptured logs `captureSession_SetConfiguration … Cam/Audio:0/1`,
`starting source node <AudioDevice, BWAudioSourceNode>`, `AURemoteIO … input
client: 6 ch, 48000 Hz` and `captureSession_FileSinkStartRecording`. The
sound plugin delivers (`stream 0: 2.15 s, 24 reads, in 98304 frames …`).
Every recording then ends about 2 s in with cameracaptured crashing; §7.

## 7. The Audio Mix analysis that crashes cameracaptured

The crash (`cameracaptured-2026-10-03-195510.ips` and three more):
`EXC_BAD_ACCESS (SIGSEGV) KERN_INVALID_ADDRESS at 0x300` in
`BNNSGraphContextMakeStreaming`, under `MIL2BNNS::loadContext` →
`NeuralNet::NeuralNet` → `AUNeuralNet::Initialize` → `DSPGraph` →
SoundAnalysis → `-[AudioRemixSessionManager startNewSessionBlocking]`.
Voice Memos sees `AVFoundationErrorDomain -11819` (media services were reset).

### Why there is a remix session at all

* Voice Memos records spatial audio when MobileGestalt answers
  `DeviceSupportsSpatialAudioCapture` (`RCDeviceSupportsSpatialAudioCapture`,
  behind `RCSpatialAudioCaptureIsAvailable`, VoiceMemos framework). The
  guest answers as the D47 it was built from.
* `CaptureSessionRecorder` then requires first-order ambisonics: in the app
  binary, right after creating the `AVCaptureDeviceInput`, it calls
  `isMultichannelAudioModeSupported:2` and, only if YES,
  `setMultichannelAudioMode:2` (0x1001b274c–0x1001b2760); NO branches to a
  `swift_allocError` (0x1001b28bc), the same error type its other failures
  use. There is no stereo fallback in that path.
* `isMultichannelAudioModeSupported:` ends in
  `-[AVCaptureFigAudioDevice isAudioCaptureModeSupported:]`, which answers
  mode 2 from the source attribute `cinematicAudioCaptureSupported` and mode 1
  from `builtInMicrophoneStereoAudioCaptureSupported` (the two
  `objc_msgSend` stubs it tail-calls). D47's microphone entry sets both.
* The movie-file head pipeline (`_buildMovieFileSinkHeadPipeline…`,
  0x1b0728ac0) adds a `BWAudioRemixAnalysisMetadataNode` next to the
  "Cinematic Audio Converter" when its metadata configuration asks for one;
  `FigCaptureMetadataObjectConfigurationRequiresSpatialAudioMix` keys that on
  `kCMMetadataIdentifier_QuickTimeMetadataSpatialAudioMix`. That the
  ambisonic mode is what puts this identifier in Voice Memos' configuration
  is inferred, not traced.
  Its start marker runs `startNewSessionBlocking`, which builds a SoundAnalysis
  `SNMovieRemix` session; that is the neural net that faults.

So stripping `cinematicAudioCaptureSupported` from the source (option a)
would not give a plain recording: Voice Memos would stop at
`isMultichannelAudioModeSupported:` with its own error instead.

### Why the neural net faults

Not established. audiomxd loads and runs a neural net through the same
`MIL2BNNS` path in the same recording (the SpatialCapture wind model,
`graph size is 1032192 bytes`, `context size is 3752 bytes`, `Successfully
loaded`), from a `.mil` it compiles to `.ir` in its own cache. cameracaptured's
remix model is shipped as `.ir` (`MIL2BNNS extension is '.ir'`, `graph size is
1359872 bytes`) and faults in the next step, making the streaming context.
That the precompiled graph targets something the VM's CPU or BNNS build does
not have is a guess.

### What the hook does

The node is written for a session that does not start
(`-[BWAudioRemixAnalysisMetadataNode renderSampleBuffer:forInput:]`,
0x1b0600d88):

* a non-zero return from `startNewSessionBlocking` (0x1b06010bc `cbnz w0`)
  skips setting `_shouldSendData` and goes to `emitSampleBuffer:` — the audio
  passes through;
* `submitAudioBuffer:` is called only after `sessionReady` returns YES;
* `-finishAndGetResultsBlockingWithStartingPTS:andEndingPTS:` returns an
  error when there is no subscriber (`ldr x0, [x0, #0x10]; cbz`) instead of
  blocking, and `_sendRemixMetadataSampleBuffer` ignores its result.

`VCamCaptured/Microphone/VCamMicrophoneRemix.m` replaces
`-[AudioRemixSessionManager startNewSessionBlocking]` (`- (int)`, checked
against the runtime type encoding before wrapping). While the daemon is
running on the microphone-only provider, it returns -16992, the code the
method's own failure path signals, without creating the session; otherwise it
calls the original. The recording keeps its ambisonic audio and loses only the
Audio Mix analysis track's data.

Not yet run in a guest. To check: `vcamcaptured.log` has `remix: wrapped …` at load and
`Audio Mix analysis session not started (-16992)` at the first recording;
cameracaptured's pid survives a recording; then the `vpquery.log` line and a
non-silent `.m4a`.

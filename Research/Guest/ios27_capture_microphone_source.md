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
in §5 answers. That second build has not run in a guest yet: its install
stopped at Launchpad's administrator prompt.

Still to check, in order, once it runs:

1. `vcamcaptured.log`: `mic source: model D47, 1 source info(s), provider …,
   hasMicSource=1`, then `serving the microphone-only one`, and no
   cameracaptured crash report.
2. Voice Memos Record: no `CaptureSessionRecorderError`; cameracaptured's
   `captureSession_SetConfiguration` reads `Cam/Audio:0/1`.
3. `/var/mobile/vpquery.log` gets a `stream 0: … reads, in … frames` line,
   and the `.m4a` under the Voice Memos app group's `Recordings/` decodes
   (`afconvert` to WAV) to something that is not zeros.

The mic-only provider hands out a source; whether `BWAudioSourceNode` then
runs in cameracaptured without anything else from the camera device is not
established until step 2.

# tvOS 27.2 Setup input investigation

## Scope and result

Static and live inspection of the native 27.2 beta `Setup` executable (SHA-256
`52815e2959731c961cd259e74c98d6d46263b13a4daca7d9789ee734fea4e44c`),
plus the matching pristine UIKitCore dyld-cache image. Live diagnostics used
the separate `tv4k4-native-setup` clone, preserving the user's configured VM.
Test preparation used `vm clone --new-identity` and reset only the clone's
SetupDone, SetupFinishedAllSteps, and TVBuddyCompletedSuccessfully to false
to exercise the assistant. No tool forced those values to completed; the
source VM's preferences were never reset.
The new assistant remains the intended path;
selecting legacy TVSetup is not a solution to this input issue.

The ordinary consumer Select event has the correct native press type. No
Bluetooth-pairing requirement, HID sender-ID test, or service-identity test was
found in the Hello tap callback or the inspected window delivery code. The
failure is now localized to deferred focus. At actual Select delivery, the
key window is foreground-active, `dropsEvents` is false, and the press is type
4, phase began, force 1. The focus system has no focused item, but its deferred
target is the native Hello SwiftUI focusable item. One normal Up commits that
target; the next Select hits the verified Hello callback and opens Language.
The native `_performDeferredFocusUpdateIfAvailable` method also returns YES
and commits the same target without an arrow. That initialization alone expires
after the native 60-second idle timer; timestamps explain the delayed first-
Select prototype failures. An immediate Select hits the native callback.
The live behavior is `_UIFocusBehavior_WaffleIron`, effective deferral 3, with
no explicit override. Native TV behavior's deferral is 0. Setting the native
override to 0 retains focus past 80 seconds and allows selection of English
and entry to the country picker without an arrow.

The adapter applies that native TV button-focus policy only to an active key
`Setup.EventDroppingWindow` with WaffleIron/default-3/no-override state. It
preserves other explicit policies and uses UIKit's native setter, preference
search and eligibility checks. Scene/key/focus notifications recheck after
native updates finish; there are no private-ivar writes, swizzles, polling
timers or changes to Setup's actual input/readiness/step callbacks. Installed
bundle `da14d7a4` passes the first actual panel Select after more than 65 seconds
idle at Hello; native Manual setup then passes activation and completes to Home
after user-confirmed Terms. Native TV completion/version preferences are set by
Setup itself; no tool forces the completed state.

A separate host transport issue was isolated on Language: an AX panel tap
left English focused, while the identical direct `input.hid` Select entered
Country or Region. Cancelling queued input on panel key loss also cancelled
already-completed AX taps. Press tickets now preserve completed taps across
focus changes while cancelling unfinished holds; a separate connection epoch
prevents any old tap reaching a later guest. The host harness exercises the
actual AX button and view release order for both cases.

## Hello gesture and readiness

`TVHelloView`'s body (`0x100044ba0`, call sites `0x100045418` and
`0x100045528`) attaches `.focusable(true)` and `.onTapGesture(count: 1)`.
Its callback thunk `0x1000496b4` reaches `0x100047600`. There is no
`onMoveCommand` modifier in this Hello body; that modifier is used by other
Setup screens.

Before logging `Remote pressed.` and invoking `remotePairedHandler`, the
callback requires both:

1. `TVHelloManager._hasDrawingStarted == true` (byte at instance offset `0x28`).
2. The installed SwiftUI `Environment<ScenePhase>` equals `.active`.

These checks do not inspect the paired-remote state. A different asynchronous
path can advance after a remote becomes paired, but it does not make pairing a
prerequisite for the local tap path. The eventual parent callback
`0x100077520` checks the server is still in `.hello` before sending
`CSKStepHelloServer.Command.helloAnswered`.

The drawing flag is a real rendering lifecycle signal, not a pairing flag:

- `CursiveHelloViewController` configures
  `SASBookendCallbackConfiguration.onAnimationWillBegin` in `0x10010afd8`.
- Its closure reaches `0x10010b280`, which yields
  `DrawingProgress.started(languageCode:)` to `drawingContinuation`.
- `TVHelloManager` consumes that AsyncStream in `0x100040f7c`; the started
  case sets the `0x28` byte through Observation mutation (and retains `true`
  on subsequent starts).
- `TVHelloView`'s drawing-state `onChange` reaches `0x100048c04`, which
  invokes the distinct `drawingStartedHandler` when the flag becomes true.

`0x1001ba1f4` reads the installed ScenePhase environment. Its fallback emits
SwiftUI's runtime warning about reading an Environment outside an installed
View; it does not query an XPC service or entitlement. Static inspection does
not establish the actual guest's phase or focus at the failed press.

## Window suppression boundary

`Setup.EventDroppingWindow.sendEvent:` reaches `0x10010cce4`. For press events
it tracks press identities so a sequence rejected at its beginning does not
later deliver an orphan release. It uses the window's `dropsEvents` gate and
press phases, without a sender/service-ID check in the inspected code.

The useful debug message is already shipped:

```text
sendEvent presses dropsEvents=%{bool}d dropped=%ld deliver=%{bool}d phases=[%s]
```

Its logger is subsystem `CompanionSetup`, category `EventDroppingWindow`.
The exact subsystem is independently confirmed by the matching cache's
`CSKConstants.logSubsystem` getter at `0x1d2c7b13c`, which returns that Swift
small string. Hello's logger uses the same subsystem, category `TVHelloView`.

**The window message is conditional, not an event trace.** A full control-flow
recheck after enabling debug and cold-booting the setup-test clone establishes
that `dropsEvents == false` together with an empty `droppedPressIDs` set skips
the logger entirely. At `0x10010d088`, a set drops flag reaches the logger at
`0x10010d0bc`; otherwise the stored dropped-set count is tested at
`0x10010d0b4`. Zero branches to `0x10010d614`, then `0x10010d3cc`, bypassing
both logger initialization and `os_log_type_enabled`. Normal delivery can
therefore produce no `EventDroppingWindow` message even with debug enabled.
The eventual call to `super.sendEvent:` remains conditional on the computed
delivery Boolean at `0x10010d5d8` / `0x10010d5f0`.

The window logger constructor `0x10010cc78` uses the exact category literal
`EventDroppingWindow` at `0x10027b3e0` and the CSK subsystem getter. The log
level is explicitly Debug (`0x10010d198`). It is neither a nil-logger fallback
nor compiled-out logging. Hello's constructor `0x1000443b0` independently
encodes `CompanionSetup` / `TVHelloView` as Swift small strings; its
`Remote pressed.` message uses **Default** at `0x1000478fc`, after both the
drawing-started and active-scene guards. Absence of the window message cannot
localize the input failure; absence of `Remote pressed.` remains consistent
with missing tap focus or an unmet Hello guard.

Two callers control suppression:

- `TVMainSetupView` observes
  `server.uiState.restartImminent || server.uiState.isShowingScreenSaver`.
  `0x1000602e0` gates the scene's EventDroppingWindows. When the observed
  condition becomes false, its task clears suppression after 0.25 seconds
  (`0x100060f48` / `0x1000610cc`).
- During `.hello`, `0x100061834` detects `.pairing` → `.paired` and briefly
  gates delivery before its clear task (`0x1000623e0` / `0x100062564`).

The main view also installs FocusState binding and default focus with
`DefaultFocusEvaluationPriority.userInitiated`. Neither existence of the
rendered animation nor a healthy PBS display-state query proves that the
intended Hello view has input focus.

## Native remote mapping, verified on 27.2

UIKitCore's `__UIEventHIDPressTypeForKeyboardHIDEvent` at `0x194776f54`
reads only keyboard usage page (`0x30000`) and usage (`0x30001`). It maps:

| Consumer page `0x0C` usage | UIKit press type | Intended control |
| --- | --- | --- |
| `0x41` | 4 | Select |
| `0x42`, `0x43`, `0x44`, `0x45` | 0, 1, 2, 3 | Up, Down, Left, Right |
| `0x46` | 5 | Siri Remote Back / Menu |
| `0x224` | 7 | Different Back press; not the Menu mapping |
| `0x40` | 17 | TV / Home |
| `0xCD` | 6 | Play/Pause |
| `0xE2` | 20 | Mute |
| `0xE9`, `0xEA` | 102, 103 | Volume Up, Down |
| `0x30` | 104 | Power |
| `0xCF` | 504 | Voice Command |

Keyboard Return (`0x07/0x28`) is not Select in this conversion; a UI may
separately handle its keyboard event. Thus Return alone is not a decisive
comparison for the consumer Select gesture path. This conversion does not
prove all earlier backboard or focus routing accepts an arbitrary event sender.

`GuestAPI` routes ordinary `input.hid` requests to `hidEvent`/`hidPress`.
`vp_hid_keyboard_hold` and its explicit KeyboardLongPress field are used only
when `long_press: true` is requested. Earlier ordinary Select trials did not
take that branch; the hold helper does not explain their failure.

## PineBoard's actual routing and activation gates

`-[PBHIDEventDeliveryManager _lock_enableNormalHIDEventDelivery]` installs
two BKS discrete-dispatch rules: a system predicate to `systemTarget`, and a
keyboard-focus predicate to `keyboardFocusTarget`. Both predicate constructors
explicitly clear `senderDescriptors`.

The keyboard-focus predicate removes the system press set, then adds
`[30, 31, 4, 0, 3, 1, 2, 32, 33]`. Select (4) and arrows (0–3) therefore
take the ordinary keyboard-focus route. The system predicate removes that set
and retains such controls as Menu (5), AC Back (7), Home (17), power and volume.
This is shipped PineBoard behavior, independent of the SDK usage labels.

`-[PBSceneManager _eventsCanBeDeferredToSceneHandle:]` requires:

- A scene exists and is valid.
- Its settings are foreground and `contentState == 2`.
- For `UIApplicationSceneSpecification`, `isUISubclass` is true and
  `(deactivationReasons & ~0x20) == 0`.

Every rejected case has a `Will not defer events to … scene` log, including
the scene identifier; the deactivation case logs the reason mask description.
`_updateFocusDeferralsIfNeeded` creates a BKS target with PID and scene token,
installs it with reason `PineBoardFocusDeferral`, and logs
`Updated events to new focused scene … pid: …`.

The scene layout's event-focus acceptance also follows readiness:
`PBApplicationSceneView.canBecomeFocused` requires effective presentation
mode 3, `_eligibleForFocus`, and `sceneHandle.isContentReady`.
`PBSceneLayoutViewController.setFocusedSceneLayoutElement:` calls
`setAcceptsEventFocus:` with the element's readiness.

These checks give a concrete scene/focus boundary to measure. They do not prove
the failed new Setup run had a bad scene or require altering any readiness gate.

## Original live diagnostic plan

Use the unmodified new Setup path and a normal consumer Select down/up pair
with one stable sender and a short physical-style hold. Do not synthesize
pairing or send `helloAnswered` directly. Capture these boundaries for that
single press:

1. Backboard/PineBoard HID routing and the foreground scene receiving the event.
2. `EventDroppingWindow` debug message, plus the actual press type and phase.
3. If delivered, Hello's focused view, `_hasDrawingStarted`, and ScenePhase at
   `0x100047600`. Prefer read-only logging of these values to modifying them.
4. The normal `Remote pressed.` then `Hello view remote paired. Going next.`
   messages and the next setup screen.

This separates a transport/device-metadata fix from a scene/focus fix. The
offline evidence supported normal Select and Menu event mappings for the new
remote panel, but did not then establish a fix for Hello. Do not
restore legacy feature overrides, force drawing/paired state, broaden Setup
entitlements, or remove readiness checks to make the test pass.

### Observer-only diagnostic hook design

The first useful hook needs no private Swift ABI or fixed image offset:

1. Restrict injection to `com.apple.Setup`; resolve
   `_TtC5Setup19EventDroppingWindow` by Objective-C runtime name and wrap
   `sendEvent:` using the project's chosen runtime-hook facility. Always call
   the original exactly once with the original event.
2. For the bounded test press, record window class, key-window status,
   `windowScene.activationState`, scene session identifier, and each
   `UIPress`'s type, phase and timestamp before and after the original call.
   Read `dropsEvents` with `class_getInstanceVariable`/`ivar_getOffset` and a
   byte load; do not write it. Query the scene's current focus through an
   public read-only `window.windowScene.focusSystem.focusedItem` accessor.
   Log numbers and runtime class names, not typed text or account content.
3. Wrap `SASBookendCallbackConfiguration`'s verified Objective-C methods
   `initOnAnimationWillBegin:onAnimationDidFinish:` and
   `setOnAnimationUIUpdateSignal:` to add logging while preserving and invoking
   the supplied blocks unchanged. Check method encodings and block ABI before
   implementing wrappers. This distinguishes a drawn background from delivery
   of the Cursive Hello lifecycle callbacks.
4. If the window receives and delivers Select but Hello remains inert, measure
   the two actual gates. `_hasDrawingStarted` is an Objective-C ivar on
   `Setup.TVHelloManager`; resolve its offset dynamically on a captured live
   instance, using a weak reference and main-thread access. Do not heap-scan or
   hardcode `0x28` in shipped compatibility code. The SwiftUI ScenePhase is a
   value-type environment, so `windowScene.activationState` is useful context
   but is not a substitute for reading the callback's installed environment.
   Capturing those Swift values requires a Swift-ABI-aware diagnostic or a
   debugger at the semantically found tap callback; do not cast it to an
   ordinary C function pointer.
   Matching metadata exposes no Objective-C methods on
   `_TtC5Setup14TVHelloManager`, so there is no concrete Objective-C `init`
   hook for capturing this instance. Do not assume NSObject initialization or
   KVC support on its `_SwiftObject` superclass. A debugger can inspect focus
   without changing it through `[UIFocusDebugger status]`,
   `preferredFocusEnvironmentsForEnvironment:`, and
   `checkFocusabilityForItem:` on the main thread; these declarations are in
   the selected tvOS SDK's public UIKit headers.
5. In PineBoard, observer wrappers on
   `PBSceneManager._eventsCanBeDeferredToSceneHandle:` and
   `_updateFocusDeferralsIfNeeded` should log the original result, scene PID,
   readiness/foreground/deactivation values and selected target. Preserve the
   original result and all original routing calls.

Enable debug for only `CompanionSetup` / `EventDroppingWindow` and
`CompanionSetup` / `TVHelloView` during the bounded capture. Producer
preferences and live-reader flags are separate controls; both must be checked.

### Scoped logging validation, 2026-10-24

The guest has no `/usr/bin/log`. Matching tvOS 27.2 `LoggingSupport` exposes
`OSLogPreferencesSubsystem.initWithName:` and
`OSLogPreferencesCategory.initWithName:subsystem:`. Retain the subsystem while
using categories: the latter store it weakly. Category `enabledLevel`,
`persistedLevel`, `effectiveEnabledLevel`, and `effectivePersistedLevel` use
signed 64-bit values (`Tq`); `isLocked` is `BOOL`. `setEnabledLevel:4` selects
the preferences enum's `debug` value, rather than `os_log_type_t`. The setter
sends a synchronous preferences-type-3 install to `com.apple.logd.admin` but
discards installation errors. Verify persistence with a newly initialized
subsystem and its on-disk category dictionary, not only the mutated instance.

A temporary native helper initially failed readback without logging-admin
authorization. Signing that diagnostic helper with `platform-application` and
`com.apple.private.logging.admin` allowed the two category entries to persist
as `Level.Enable = debug`; a fresh helper also reported
`os_log_type_enabled(..., OS_LOG_TYPE_DEBUG) == true`. These are temporary
diagnostic privileges, not additions to the product. Before mutation, both
category entries were absent. The helper saves rollback state, refuses
preexisting target entries, and restores absent entries through category
`reset`; `_resetCategory:` removes the subsystem preferences file when its last
entry is removed. It reloads between mutations to preserve unrelated entries
and refuses a changed target entry during rollback. Restore after capture.

The existing icli live reader creates `OSLogEventLiveStream`, installs its
event handler, and activates it without setting flags. Matching framework
analysis shows the default flags are zero. The host `/usr/bin/log` live path
proves bit 0 includes Info and bit 1 includes Debug: its `_log_flags_s` metadata
orders `show_backtrace`, `show_info`, `show_debug`, and its live path reads
offsets `+4` / `+8` before OR-ing stream flags `1` / `2`. Matching tvOS
`_activateLiveStream` maps those bits to diagnosticd request flags `0x100` /
`0x20`. Set `flags = flags | 3` **before** `activate` to include both. These
reader flags do not alter producer preferences.

A separate temporary native capture, bounded to 30 seconds / 5,000 entries and
filtered to Setup and PineBoard, then received real Info and Debug events
(one capture: 4,579 entries, including 1,497 Debug). This proves the previous
notice-only captures did not cover all severities. No `CompanionSetup` events
appeared in that capture, so absence alone still does not establish which
Setup gate failed. Event proxy properties must be sent directly through
Objective-C dispatch, as icli does: a forwarding proxy may return false from
`respondsToSelector:` for getters it nevertheless implements through
forwarding.

The subsystem spelling was independently rechecked in matching
`CompanionSetupKit`: `CSKConstants.logSubsystem` at `0x1d2c7b13c` returns Swift
small-string words `0x6f696e61706d6f43` and `0xee0070757465536e`. Their
little-endian payload is exactly `CompanionSetup` (14 bytes), without a
`com.apple.` prefix. LoggingSupport's setter has no explicit app-relaunch or
notification call beyond its logd request; propagation to existing producer
handles belongs to logd/libsystem_trace and was not established by this static
analysis. A cold boot of the disposable setup-test clone with the scoped
preferences installed disambiguates producer initialization.

Temporary evidence artifacts: `/private/tmp/tvremote-logging-cache-objc.txt`,
`/private/tmp/tvremote-logging-analysis.json`,
`/private/tmp/tvremote-logging-stream-analysis.json`, and
`/private/tmp/tvremote-host-log-ipswdisasm.txt`. Host CLI evidence used native
ipsw disassembly because the separate host REA provider startup timed out.

| Scoped logging observation | REA evidence ID |
| --- | --- |
| `debug` maps to preferences level 4 | `ev_e1398c4765ff2551f63f1c839ed84477a300026e7f30852da869a5ff28eb5198` |
| Category weak subsystem reference | `ev_1cece862c7cae3586c1289ae621e336e05cdbebc059d55b9cc7cd479fe9f4c64` |
| Per-category enabled setter/install | `ev_807b6898c67b7fa596836c62e8100457b944fff83199dd6422da2fd43545e7af` |
| Category reset removes entry / last file | `ev_540c83a12ace2814151c9af46986f04858750948ec64f630399e7a9821c4387a` |
| Synchronous logd admin transport | `ev_d5b61b5cd11b0339a98c3a1bac761bfb7f1ff4815904371ea5a58876986f2c8c` |
| Stream base init leaves zero flags | `ev_2be86dcf343a27119ddeed73d15519bfac0813017d1ce63ab73f353f48c038e3` |
| Matching tvOS stream flag remapping | `ev_7b92ad0bc997c0ce5252e2c0c2a5e8c858a417f90fd087e988fc93fe8033934d` |
| Complete window flow / clean-delivery log bypass | `ev_df2b9ea001b7353bf0e2822377cdf45c0d41ca3b3da61f7568526cd6bc2d5637` |
| Exact window logger constructor/category | `ev_42a1cb84ae3001d4b3061d238107ef62eeeaa9bf9be86085daebb113962f9012` |
| Exact Hello logger constructor/category | `ev_895590a11e2c40c9575904eb7acf345a8214491ec42eac832556e56520ae1b43` |
| Hello guards followed by Default-level remote log | `ev_8154a42aa29e8fd2f77d0e3f97a3f517eccc474ba272f98eca725f1552b03f15` |

## Evidence ledger

REA/Hopper decompilation is recovered pseudocode, not original source. Addresses
are analysis anchors for this build, not offsets to hardcode in a patch.

| Observation | REA evidence ID |
| --- | --- |
| Hello focusable + single tap body | `ev_a9ece8c1ed9df8b26c04a621f8451e76e44aef08c853899eaf3475501bfb7b09` |
| Tap callback drawing + active gates | `ev_a4b76a7a8aab038818e1cc5e14ff40bc473d1aa01b1654115a73e0ee62812830` |
| Exact byte load in callback assembly | `ev_2be14fc1b527e3c79040a4a437af3a70eeac4f5a359c2312043c4bbe22dbc353` |
| Parent normal hello command | `ev_4fe49dbb67bd216fdf32bda6a79a09d2d6fd330a5a9a799c0eedfb1301256a90` |
| Cursive callback registration | `ev_1088553f6e867e4df03f84d43d5a4cf4c9ac98e0c91048210bf054876a36de99` |
| Drawing started producer | `ev_89e78278c021bd0e37af362b92a73adc79c32dfb8b89f41db1920d118186bad9` |
| Drawing flag mutation consumer | `ev_b6303d4b283779ea431c6dca7564798d7c4e910ded02feff94c1caca9111e683` |
| Drawing-state view callback | `ev_5fc359a948d6c02bdffc2b7f0c7a4bd4c885458870e6bbb37bf9104697e83a5a` |
| ScenePhase environment read | `ev_efe7ddbbff8d970a0446d5729d725e9d8fd77397491a2eb3698040d40049e17f` |
| EventDroppingWindow delivery | `ev_f10ddc6196da767beae2ff919d918bf48760bd4b26ae2b90e469983e39479ab5` |
| Event logger category | `ev_358aed1a3dec665597b2e84848e7da548fbcbf5eaa36ae4b55479c07ef3d6706` |
| Main view gate conditions and default focus | `ev_24b2a147e021a95956e0ea6acf639b3d3533da77396043183889560fd442b643` |
| Restart/screensaver suppression | `ev_527f04a8b4dfb104d9a52eed3c4e8f1e493f31d8560c2749fe0ee3c3ab4ca3d5` |
| Pairing transition suppression | `ev_257280584ea93df966f312c9af31b27d8d41980ef6d439b77666c536c7f113ac` |
| Normal BKS dispatch rules | `ev_5ae109cec8fadd72f4ff461375fc61e378aa365f3d9bcf4627605787a6ebb488` |
| Keyboard-focus predicate without sender restriction | `ev_20db42f4d5b9602d1c76c36f6444d9dfd65af194ebdfa7dd4b12d85a1552242c` |
| Actual keyboard-focus press set | `ev_b91122666e8b5f9b93823757535f1bf6cdeb9c3ef010085d0f7cdee5eb103384` |
| Scene deferral readiness/activation gate | `ev_7acdd185b56827c2a53626aa0075b56d26e1f54e31fa7259def0e4ffb63da588` |
| Scene focus target and deferral update | `ev_a88ddfab6667d556462d7a885f0db790507a3090780a8b030657229b810ebc61` |
| Scene view focus eligibility | `ev_6550afe210ea5b9c1f624dac068095f89b0807eac41c40890e32e8f7fe1f039d` |
| Layout accepts event focus when ready | `ev_745c06e3e8e8d89e6bf5344f5a2175955abf0b03874552bc38c42cddfc680fa0` |

Local matching-cache disassemblies (ipsw, explicit unslid addresses, no guest
execution): `/private/tmp/tv4k4-tvos27-hidpress-disassembly.txt`,
`/private/tmp/tv4k4-tvos27-tap-press-disassembly.txt`, and
`/private/tmp/tv4k4-tvos27-tap-shouldreceive-disassembly.txt`.

## Native focus-deferral implementation evidence

Matching-cache UIKitCore was extracted with ipsw to
`/private/tmp/tvremote-uikit/UIKitCore`, SHA-256
`5ebe74b705bcb0260446ee45a58c94c82dace11d1ad7d488b20aca04b28d45dc`.
The following findings come from native ipsw symbol, Objective-C metadata,
disassembly, and cross-reference inspection. A separate REA/Hopper startup
timed out for this large image; these findings do not have REA evidence IDs.
All addresses below are unslid reveal anchors, not product offsets.

`-[UIFocusSystem _performDeferredFocusUpdateIfAvailable]` (`0x193b136a0`)
returns false if the focus system is disabled, its weak deferred target is
nil, or its effective deferral behavior equals 2. Otherwise it:

1. Preserves the existing deferred item locally and clears the stored target
   through `_setDeferredFocusUpdateTarget:nil`.
2. Builds a context with
   `_simulatedNonDeferredProgrammaticFocusUpdateToEnvironment:` using that
   preserved item; it does not select a replacement target.
3. Marks the context with `_setDeferredUpdate:YES`.
4. Returns `_updateFocusImmediatelyWithContext:`'s Boolean result.

The matching live runtime separately reported Objective-C return encoding `B`.
The method does not create, forward, consume, or replay a `UIPress`. Its true
return describes a successful focus update, not consumption of the caller's
Select event. Eligibility and focus-update handling remain in UIKit's native
context path.

The optimized Objective-C dispatch stub for this selector is `0x198065f10`.
An ipsw xref search across matching UIKitCore finds exactly two call sites:

| Caller | Call site | Native use |
| --- | --- | --- |
| `_UIFocusMovementPerformer.performFocusMovement:` | `0x193b1bd40` | Before ordinary movement, perform an available deferred update unless the request suppresses this path; a true return takes the successful-movement path at `0x193b1be1c`. This accounts for a directional press activating the already chosen item. |
| `UIFocusSystem._setOverrideFocusDeferralBehavior:` | `0x193b13e80` | When the new effective behavior becomes zero, try the deferred update before requesting an ordinary fallback focus update. |

The same dispatch-stub xref search in matching SwiftUI found no call sites.
This is a bounded direct-call result; it does not rule out dynamic dispatch
through another route or other framework images.

`_effectiveFocusDeferralBehavior` (`0x193b13db8`) returns the numeric override
when `_overrideFocusDeferralBehavior` is nonnil, otherwise
`behavior.focusDeferral`. `_UIFocusBehavior_TV.focusDeferral`
(`0x1945b21ac`) returns zero. Do not assign an invented enum name to the live
value 3, infer its source without inspecting the actual override/behavior, or
change that policy to repair input. In the value-3 branch of
`_prefersDeferralForFocusUpdateInContext:` (`0x193b1325c`), UIKit consults the
request's `allowsDeferral`, the next item's deferral mode, and the system's
`hasSeenFocusedItem` state.

The independent `waitingForFocusMovementAction` property is a Boolean. Its
getter (`0x193b190b0`) reads the byte at `0x3c` and its setter
(`0x193b190b8`) writes it. Runtime inspection should use the selector or
resolved ivar `_waitingForFocusMovementAction`, never that offset. A false
value does not imply the separate deferred target is empty.

Matching SwiftUI Objective-C metadata declares
`_TtC7SwiftUI28UIKitSelectGestureRecognizer` as a subclass of
`_TtC7SwiftUI22UIKitGestureRecognizer`, with its own
`pressesBegan:withEvent:`, `pressesChanged:withEvent:`,
`pressesEnded:withEvent:`, and `pressesCancelled:withEvent:` methods. Its
`pressesBegan:` Objective-C thunk (`0x1c1e086b4`, shared bridge
`0x1c1e086e4`) accepts `self`, `_cmd`, `NSSet<UIPress *> *`, and
`UIEvent *`, and returns void. The Swift body (`0x1c1e08e18`) converts real
presses to select-listener events, sends them through the event bridge, and
sets the recognizer's state. A compatibility wrapper should retain that
original call exactly once, including when the deferred-focus attempt returns
false, and leave change/end/cancel delivery unchanged.

Bounded UIKit focus logging is also source-backed. The `UIFocus` category's
override table includes key `UIFocusLoggingEnabled` from both UIKit's
`NSUserDefaults` suite `com.apple.UIKit` and the process's standard defaults.
Using the latter can scope a temporary diagnostic to Setup, with its prior
value restored afterward. Category refresh is registered under Darwin
notification `com.apple.UIKit.LoggingPreferences`; the exported
`__UILogSyncCategories()` function (`0x194542a68`, Mach-O symbol
`___UILogSyncCategories`) synchronizes associated category flags directly.
These logging controls are diagnostic only and are not part of the input fix.

Reproducible local evidence files:
`/private/tmp/tvremote-focus-system-disasm.txt`,
`/private/tmp/tvremote-focus-deferred-callers.txt`,
`/private/tmp/tvremote-focus-movement-deferred.txt`,
`/private/tmp/tvremote-uikit-objc.txt`,
`/private/tmp/tvremote-swiftui-objc.txt`,
`/private/tmp/tvremote-swiftui-select-thunk.txt`, and
`/private/tmp/tvremote-swiftui-select-began.txt`.

### Native focus-policy and idle-expiry evidence

Runtime inspection on the setup-test clone identified the actual behavior as
`_UIFocusBehavior_WaffleIron`, with effective deferral value 3 and a nil
override. The scene's public `focusSystem`, `window._focusSystem`, and
`window._focusSystem._preferredFirstResponderFocusSystem` were the same
instance. WaffleIron's `focusDeferral` getter (`0x194546db0`) reads its
configured `_focusDeferral` field; the ordinary `_UIFocusBehavior_TV` getter
(`0x1945b21ac`) returns zero. The earlier possibility of an explicit scene
override producing the observed 3 was therefore ruled out for this live
instance.

`_setOverrideFocusDeferralBehavior:` (`0x193b13e24`) is a void method with one
`NSNumber *` argument. It stores the override and then evaluates the native
effective policy. A nonzero effective policy invokes
`_startDeferringFocusIfSupported`. Zero first attempts
`_performDeferredFocusUpdateIfAvailable`; if that does not succeed, it calls
`requestFocusUpdateToEnvironment:self` and `updateFocusIfNeeded`. It does not
write Setup state, select a hardcoded leaf, synthesize input, or bypass the
ordinary focus eligibility path. Existing nonnil overrides must be preserved
by a compatibility adapter rather than overwritten indiscriminately.

The timer is material to testing this policy. `_tickHasSeenFocusedItemTimer:`
(`0x193b13818`) invalidates its previous timer and, for effective policy 3
with a focused item, schedules a one-shot timer for **60 seconds**. Its Boolean
argument controls whether to mark `hasSeenFocusedItem` first. A successful
focus update derives that argument from the context's `_isDeferredUpdate`
(`0x193b16e50`–`0x193b16e60`, or a direct true branch when appropriate).
The native deferred-update method marks its context as deferred, so both a
lifecycle activation and the corresponding first-directional-input activation
can start this timer naturally.

When the timer fires, `_hasSeenFocusedItemDidExpire` (`0x193b13d20`) invokes
`_startDeferringFocusIfSupported`. That method resets the seen-item bookkeeping
and, when the effective policy and item mode permit, drops the current focus
and stores the old item as the deferred target. Thus a lifecycle-only focus
activation can appear successful and still leave the first later Select
without a focused item after the idle interval. One prototype's initialization
log preceded the user-interface capture by more than 60 seconds; an immediate
native activation followed by a real Select reached the unmodified Hello
callback. Neither observation proves that a lifecycle-only adapter remains
effective after idle.

`_startDeferringFocusIfSupported` performs the drop using
`_dropFocusAndStartDeferring:NO suppressUpdate:YES`. The suppression does
**not** suppress `UIFocusDidUpdateNotification`: normal focus-update callbacks
still reach `_UIFocusSystemSceneComponent._focusSystem:didUpdateFocusInContext:`
(`0x193bbdfc0`), which posts the public notification with the focus system as
its object at `0x193bbe080`–`0x193bbe090`. Suppression skips only the fallback
focus request in the completion block at `0x193b17a68`–`0x193b17a9c`.
The old focus item is stored as the deferred target only after this drop and
synchronous notification return (`0x193b13ccc`). An observer that needs that
target must therefore defer its work to the main queue and recheck the current
window, scene, focus-system identity, and policy there.

The scene component can replace an explicit override during
`_updateFocusSystemState` (`0x193bbb2ec`). If replacing zero with nil changes
the effective policy back to 3 while an item is focused, the native drop posts
the notification above. If focus was already nil, no new focus notification is
guaranteed; scene-activation and key-window notifications provide separate
lifecycle opportunities. Under effective policy zero, expiry of an existing
timer may reset bookkeeping, but `_startDeferringFocusIfSupported` does not
drop focus.

A manual diagnostic call setting the native override to zero kept the normal
Language focus through more than 80 seconds of idle, after which a real Select
RPC advanced to Region. This validates the native setter's policy behavior in
that test; validation of the final installed product bundle is a separate
step. The source adapter is intended to apply the same native button-focus
policy only to an active, visible, key `Setup.EventDroppingWindow` with
WaffleIron behavior, effective value 3, and no existing override. It leaves
Setup's drawing, scene, press-suppression, pairing, and completion gates intact.

Additional native evidence files:
`/private/tmp/tvremote-focus-immediate-env.txt`,
`/private/tmp/tvremote-focus-send-notifications.txt`,
`/private/tmp/tvremote-focus-scene-notification.txt`,
`/private/tmp/tvremote-focus-startdefer-callers.txt`,
`/private/tmp/tvremote-focus-override-callers.txt`,
`/private/tmp/tvremote-focus-scene-state.txt`, and
`/private/tmp/tvremote-focus-preferred-system.txt`.

## Final policy component trial and native activation boundary

At 20:50:58 UTC on 2026-10-24, the exact final built
`libvphonetvsetupfocus.dylib` was loaded into the newly relaunched Setup
process 342 on the diagnostic clone. No manual policy setter was called in
that process. Its initialization log reported the native TV button-focus
policy, and read-only inspection confirmed effective policy 0, override 0,
and a native focused item. Ordinary remote input selected Set Up Manually
from Quick Start and entered Activating Apple TV. English and United States
were preserved. This is an in-memory payload trial, not an installed
load-command/cold-boot validation.

Activation then displayed Activation Error. Dismissing OK returned to Quick
Start. One normal retry, captured in
`/private/tmp/tvremote-activation-retry-setup.json` and
`/private/tmp/tvremote-activation-retry-daemon.json`, logged five native
activation attempts failing with `NSOSStatusErrorDomain` code -71136, while
mobileactivationd received `createTunnel1SessionInfoWithCompletionBlock:`
requests from Setup. No agreements, accounts, or privacy permissions were
accepted; setup completion remains false.

The live mobileactivationd was pulled to
`/private/tmp/tvremote-live-mobileactivationd`. The existing activation patch
resolves its getter through agreeing symbol-table and Objective-C metadata
anchors, and its scratch-copy trial finds the original Boolean-field getter,
not an already patched getter. Both the TV preset and TV guest admission
currently exclude this patch. Whether enabling it covers the new assistant's
activation path requires matching binary inspection and live validation.
The debugger was detached, its temporary launch job unloaded, and the clone
stopped before further environment changes. The original VM was not reset.

## Native activation-state path and bounded TV admission

Offline inspection of that pulled tvOS 27.2 mobileactivationd establishes
that the existing patch targets a real native local-activation path in this
daemon. Its SHA-256 is
`4393ac6c559340933ab28b627c0cb96af4ce8b8f7b4c30d2f1884252a9e9b367`.
`-[DeviceType should_hactivate]` (`0x100017a14`) reads its original Boolean
field. `_use_hactivation` (`0x10001800c`) calls that getter on the shared
DeviceType. In `_dealwith_activation` (`0x10001ed48`), a true result logs
`Hactivation is enabled, short circuiting activation state to Activated.`,
writes DataArk `ActivationState = Activated`, `BrickState = false`, and
`ActivationExpired = false`, and returns successfully before activation-record
validation. The normal migration block (`0x10001cf00`, call site
`0x10001da70`) invokes this operation after its migration/registration work;
`_handle_unbrick` is another caller. The XPC method
`getActivationStateWithCompletionBlock:` (`0x100053ebc`) reads that same
DataArk ActivationState after migration and returns it in its result
dictionary. Missing state defaults to Unactivated; incomplete migration returns
Unavailable. This is native daemon state handling, not a Setup completion
override.

REA evidence: getter
`ev_114d4b4b985de1005eef1553e1244cd7e6b136971431d8c514a35a050a1fb3ee`,
use-hactivation wrapper
`ev_96a884a1e699df95851e7c5d108aa6fa9e44a84fbf8c89a1d59fed4cf7f62885`,
activation operation
`ev_b26592343ade26d74c66270bcf0a797e16bbc1f2f4613b0ee2043acb028d5ad8`,
XPC state result
`ev_4651dc76599f0a106990a77cf003629b10c2fbb39fba433196dfe84b418cce5b`,
and migration block
`ev_b5465951756c117b161ea10e77b13b68ca2f6e631eb310461e0c76c1feac8b9d`.
The provider-neutral snapshot is
`/private/tmp/tvremote-mobileactivationd-rea.json`.

The new assistant's matching CompanionSetupKit client also checks this native
activation state before creating a session. The extracted framework SHA-256 is
`a74b8220cc6419bcc66a4d2e8f9c42d2f97a951591dd51c6e763a807e2cca81e`.
Its checking phase logs `activation state checking` at `0x1d27f4460`, calls
the CSKMAEGetActivationState wrapper (`0x1d27fe4c4`) at `0x1d27f4638`, and
awaits its result. The wrapper's callback calls
`MAEGetActivationStateWithError` at `0x1d27fea5c`. The continuation logs the
result at `0x1d27f4978`, then compares it to
`kMAActivationStateActivated` and `kMAActivationStateFactoryActivated`.
The matching cache identifies the imported constant pointers at
`0x1e0141d58` and `0x1e0141d68`, respectively (`ipsw dyld a2s`). Either
equality reaches the normal nil-error async return at `0x1d27f4aa4` through
`0x1d27f4c60`. Only nonmatching states reach the later
`session request create` log at `0x1d27f4e98` and session-request wrapper.
Therefore the daemon's existing Activated state is accepted by the new native
client without editing that client's activation or completion decisions.

REA string/xref evidence:
`ev_0a9860e7983b0c477aa9f4734ebf27091cfb9466c338ebdc3ffcd16000ae5360`,
`ev_158fb534529ab7e451e6344f031905304716ad0dc1490f4f26f676cba4cd5ad2`,
and `ev_b36b585cfcfe82afff402182e9a1019e7e70d64b705b814bcc96b50d3aade663`.
Function dossier
`ev_2a41bd6918d78f3eaa09a2dbf8b830598d16c42a10b95afc7ecea81c302a16f8`
corroborates the state-comparison path. Hopper merged multiple Swift async
continuations into an oversized function; the bounded branch conclusion was
checked against native instruction disassembly, saved in
`/private/tmp/tvremote-csk-activation-state.asm` and
`/private/tmp/tvremote-csk-activation-wrapper.asm`. The REA snapshot is
`/private/tmp/tvremote-csk-rea.json`; the native provider was closed after this
inspection. These addresses are research evidence, not patch offsets.

The TV admission uses a separate declaration,
`system-mobileactivationd-exp-tv_activation`, gated to tvOS 27.2 and admitted
only for arm64e Apple TV. It reuses the unchanged `patch-mobileactivationd`
implementation. The installer selects one activation declaration per device
family for the shared file and reversible backup. The old global activation
declaration remains excluded from TV, preserving older TV preset behavior.
Static review found no routing blocker. A scratch trial using the pulled
binary successfully patched and re-signed it with its original entitlements
preserved; code-signature verification passed and a second patch was a no-op.
The re-signed scratch SHA-256 is
`999d10f1cd33e06a3ebd5000127022453b91c45ede55708d7d17a0bbf930c73b`.

This establishes the proposed fix's native state path and offline patch
compatibility. It does not prove that the final installed daemon boots,
reports Activated to Setup, or completes the assistant. Those remain live
cold-boot validation steps after bundle installation and environment update.
The observed -71136 failures alone do not establish the numerical error's
underlying meaning or prove that this omission is the only activation issue.

## Read-only TV completion reporting

A completed TV guest can have `SetupDone = true` while the iPhone
`SetupVersion` key is absent. The daemon previously interpreted that absence
as version zero and compared it with `BYBuddyIOSCurrentVersion` (11), falsely
reporting setup pending. The matching tvOS SetupAssistant framework uses a
different version key and an additional completion condition.

Inspection of the matching extracted SetupAssistant (SHA-256
`51aa489f9d09ce8a78b267394276356df101a7db64d2fcf83c66c27994d636f6`)
finds the TV path in `_Internal_BYSetupAssistantNeedsToRun`
(`0x1a7033aa8`). After its general supported-device and audio-accessory gates,
the TV rule reports pending when any of these is true: `SetupDone` is false,
`TVSetupVersion` is below the native TV version, or
`TVBuddyCompletedSuccessfully` is false. At `0x1a7033c40` it reads
`TVSetupVersion`, accepts values above 14, and at `0x1a7033d30` checks the TV
completion Boolean. The exported Int32 `BYBuddyTVOSCurrentVersion` at
`0x1a705a7c4` contains 15 in this build; the adjacent iOS constant contains
11. Its exported `BYBuddyTVOSVersionKey` is `TVSetupVersion`.
The native integer preference reader uses `com.apple.purplebuddy`, user
`mobile`, and any host. Its Apple TV discriminator compares MobileGestalt
`DeviceClassNumber` with 4 (`0x1a7035150`).

REA evidence:
`ev_89652f73c821f5e89e1a7e48711fc5958d466174b7df65871be6a56b81fc8587`
and integer reader
`ev_35d80a3e106c7f22bd95d6256a017818b9f251576de010066175d2a865f43997`.
Bounded native disassembly is
`/private/tmp/tvremote-native-tv-status.asm`; the snapshot is
`/private/tmp/tvremote-setupassistant-status-rea.json`. The provider is closed.

The minimal status correction is a runtime TV-specific preference policy:
read the TV version key, load the TV current-version constant, and retain both
native completion conditions. iPhone and HomePod should keep their existing
status path. The exported `BYSetupAssistantNeedsToRun` wrapper additionally
consults its launch sentinel/cache; duplicating the verified preference rule
keeps the daemon health check cheap and avoids importing that process-dependent
cache behavior. This reporting correction must not write completion keys or
silently extend the existing iPhone setup-skip operation to TV. Native Setup
completion and observed post-completion preferences remain live evidence to
record separately.

## Installed cold-boot validation, 2026-10-24

Administrator authorization installed `8e456731`, followed by activation build
`a4b9ffc4`. Both patches were recorded applied with zero pending patches and
legacy TVSetup disabled. The first cold boot exposed a packaging defect:
`patchMachO` preserved the original Setup entitlements, but the later outer
bundle seal used the default `preserveEntitlements: false` and removed them.
Setup repeatedly terminated with TCC's missing
`NSBluetoothAlwaysUsageDescription` diagnosis. The pulled installed executable
had no entitlements, compared with the pristine executable's complete set.
This was an installation defect, not evidence that Setup needs a new Bluetooth
permission, a usage-description edit, or a TCC bypass.

Corrected build `2.13.0-local.da14d7a4` preserves entitlements at both the final
apply seal and the backup-restoration seal. Its full bundle build and admission
passed. After redeploying from the pristine backup and cold booting, the actual
installed Setup's entitlements compare byte-identically with pristine Setup.
The pulled executable verifies with the actual Info.plist and CodeResources
using host resource-content verification disabled; the focus payload and
activation daemon signatures also verify. A separate scratch restoration seal
of the pristine executable preserves its exact entitlement XML and passes full
signature verification for that scratch bundle.

Hello was visible at 21:23:00 UTC. The first guest input was one actual remote
panel AX Select at approximately 21:24:16, after more than 65 seconds idle.
It advanced to native Quick Start by 21:24:19 without directional input, direct
RPC priming, a debugger, or manual policy calls. This validates persistent
focus initialization, idle behavior, and the installed completed-tap queue fix.
The previous English and United States choices persisted, so their pickers did
not reappear on that boot.

Using only the installed remote, Down focused Set Up Manually and Select
advanced through activation to native room choice, then Office, Data & Privacy,
and Terms & Conditions. No activation error appeared. Terms initially remained unaccepted:
the computer-use tool's runtime confirmation policy requires action-time user
confirmation to accept Terms of Service or an EULA, even with prior approval.
The user was asked at the displayed screen; no completion preferences or native
step callbacks were changed while awaiting that confirmation.

The original configured VM was never reset. Its update to the corrected bundle
was started independently while the clone remained at Terms. Launchpad's
administrator authorization expires after 300 seconds; any new credential
prompt must be completed by the user before that environment update can run.

At 00:25 UTC on 2026-10-25 the user explicitly authorized the displayed Agree
action and completed the new administrator prompt. Native Setup then skipped
account sign-in through its offered route, declined optional Siri/location and
both analytics choices, preserved America/Sao_Paulo through native city search,
and advanced Welcome to Home. English/US remained unchanged; Office is only
the clone's room. Read-only checks find SetupDone=true,
TVBuddyCompletedSuccessfully=true, TVSetupVersion=15, and no running Setup.
The clone was stopped after this capture. The original VM was updated to
`da14d7a4`, booted to Home/screensaver with its prior completed state intact,
and passed actual remote navigation/Settings/Back, held TV Control Center,
Siri search/dictation UI, held Power sleep, and TV wake. Volume and mute events
were balanced, but audible volume/mute/playback effects are not claimed with
no active media. Home was restored and all inputs released.

The completed TV still made the old status API report pending, because it used
the iOS version namespace. The final read-only reporting correction separates
TVSetupVersion/BYBuddyTVOSCurrentVersion/TVBuddyCompletedSuccessfully from the
unchanged iOS/HomePod policy and existing skip operation. Its logic harness
passes 376 checks, including missing/stale/current TV state and non-TV model
boundaries; the complete bundle builds and passes admission. Candidate
`9ffd2d6e` was prepared in Launchpad, awaiting macOS administrator authentication
before live status verification. At that point both VMs remained bound to
working `da14d7a4`; the original was running and the completed clone stopped. Unused defective
intermediate bundles `8e456731` and `a4b9ffc4` were removed from the store.

At 02:08:25 UTC on 2026-10-25 the final status bundle installed successfully,
including policy and host preflight. Both VM environments were updated before
the authorization timeout. Cold boot of the completed native-Setup clone
answered vphoned in five seconds and returned this actual status:

```json
{"current_version":15,"setup_version":15,"setup_done":true,"pending":false,"running":false,"pid":0}
```

The actual UI capture `/private/tmp/tv-remote-live-9ffd-clone-reboot-home.jpg`
shows Home without Setup returning; no input was needed. The clone was then
stopped. Cold boot of the original VM also answered in five seconds and
returned the same completed TV status. Both are bound to and report the guest
environment `2.13.0-local.9ffd2d6e`; their receipts have zero pending patches,
the native focus and local-activation patches applied, and legacy setup off.
No preference resets, setup completion writes, or debugger intervention were
used for these final boots. The original VM remains running.
Its final UI capture `/private/tmp/tv-remote-live-9ffd-source-home-after.jpg`
shows Home without Setup. The actual final remote exposes all 13 enabled
controls, and Back followed by Right moves native Home focus successfully.
The original VM was left at Home with every input released.

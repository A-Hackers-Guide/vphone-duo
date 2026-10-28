# iPhone Duo: the hinge, the panels and what iOS does with them

Investigated 2026-10-27 on the Duo VM: `iPhone19,4`, board `v68ap`, iOS 27.2
(24B91020), cloudOS 26.4 (23E5207q), host an A18 Pro Mac on macOS 27 with
`hw.optional.arm.FEAT_CSSC = 0`. Static evidence comes from the 27.2 restore
archive and its dyld shared cache; runtime evidence from the guest through
vphoned. Addresses are left out: they are observations of one build, never
constants to patch against.

This continues [iphone_duo_bringup.md](iphone_duo_bringup.md), which got the
Duo's userland to boot on a host without CSSC.

## Summary

| Question | Answer | Evidence |
| --- | --- | --- |
| How does iOS learn the hinge angle? | A HID service, vendor motion page `0xFF0C`, usage `0x21`, sending events of type `0x2C` | dyld cache, below; the virtual service is matched and its events dispatched |
| Can a VM have both panels? | No: one display per VM | `_maximumAllowedDisplayCount` is 1; a second display fails configuration |
| Does SpringBoard switch layouts on one display? | No | screenshots at 0° and 180° are the same outer layout |
| Where do hinge events go in backboardd? | Into its event dispatcher, with no destination | one `destinations for Unknown event: ()` per angle set |
| Does the virtual sensor block rotation? | No | rotation is refused with the sensor cleared too |

## The device tree

`Firmware/all_flash/DeviceTree.v68ap.im4p`, `/product`:

- `artwork-device-subtype = 2034`, `artwork-scale-factor = 3`,
  `app-macho-architecture = arm64e.x1`;
- two children, `display0` (index 0, rotation 0, scale 3) and `display1`
  (index 1, rotation 270, scale 3).

Apple's published panels fill in the sizes: the outer is 1398 × 2034 at
460 ppi, the inner 1878 × 2670 at 430 ppi in its native portrait. Mounted at
270°, the inner panel is landscape when the phone is open, 2670 wide.

## The hinge sensor

### Static: who reads it

In the 27.2 shared cache (relabelled from `arm64e.x1` to plain `arm64e` so the
tools would parse it):

- **HID.framework** exports `IOHIDEventCreateHingeAngleEvent`, whose arguments
  are `(allocator, timestamp, angle, mechanicalAngle, velocity, options)`. It
  builds an event of type `0x2C`.
- **CoreMotion**'s lid-angle notifier, `CLLidAngleNotifier`, matches services
  on usage page `0xFF0C` (Apple's vendor motion page) and usage `0x21`, and
  reads the angle field of `0x2C` events.
- **SpringBoardFoundation**'s `SBFDevicePoseProvider` takes that angle and
  turns it into the device pose that decides which panel is in use.
- **SpringBoard** has a continuous-fold controller, `SBContinuousFoldController`,
  with a pair of mappings between the hinge angle and fold progress
  (`…ContinuousFoldAngleProgressForHingeAngleDegrees` and its inverse), and a
  hinge-angle HUD, `SBFHingeAngleHUDView`, behind a `SBShowHingeAngleHUD`
  default.
- **UIKit** carries the hinge state to scenes through
  `_UISceneHingeStateHostComponent`, which is how an app would learn the pose.

### Runtime: the virtual service

`libvphonehinge.dylib` runs in `backboardd` on this product type only and
creates a `HIDVirtualEventService` with that identity. vphoned's
`motion.hinge.get` reports the provider's own view:

```
"provider_running": 1, "enumerated": true, "dispatch_failures": 0,
"dispatched": 35, "configuration": { "angle": 180, ... }
```

The service is enumerated by the HID event system, and every angle set is
dispatched without a failure. Angles read back exactly: 87.5, 33.25, 0 and
180 were each published as set.

### Runtime: backboardd's routing

With the unified log captured from `backboardd` while the angle was set five
times (150°, 60°, 0°, 90°, 180°), `com.apple.BackBoard` logged five lines:

```
destinations for Unknown event: ()
```

and nothing else about them. BackBoard's event delivery receives the events,
does not know the type and has no destination for it. That fits the static
picture: the angle's consumer is CoreMotion, which matches the HID service
itself, not a BackBoard route. A real Duo has the same service, so this line
is probably normal there too; it is recorded here because it is the only
trace the events leave in the log.

Nothing in SpringBoard's or locationd's log at the default level mentioned a
pose or the angle during the capture.

### The hinge-angle HUD

`SBShowHingeAngleHUD = YES` in `com.apple.springboard`, read back as set, and
a SpringBoard restart: no HUD appeared on the outer screen while the angle was
moved (150°, 120°, 90°), screenshot 0.3 s after each change. Either the
default is honoured only on internal builds, or the pose provider does not
receive the angle on this guest. Which one is open; the default was removed
afterwards.

## One display

`VZMacGraphicsDeviceConfiguration` has a private
`_setDisplayPortCount:` and a class method `+_maximumAllowedDisplayCount`. On
this host the maximum is 1. A configuration with two
`VZMacGraphicsDisplayConfiguration`s fails:

- without changing the port count: *"Number of displays is greater than the
  configured display port count"*;
- with `_setDisplayPortCount:2`: *"The display port count is invalid, it must
  be between 1 and the maximum supported."*

So a VM cannot present `display1`. The window draws both panels from the one
display and lights one at a time.

## What SpringBoard does with the angle on one display

Screenshots of the guest's own framebuffer at 0° and 180°, home screen in
front, show the same outer-panel layout: four columns, the dock as a
vertical strip on the right, 466 × 678 points at 3×. `device.screen` reports
the same size at every angle.

SpringBoard's fold logic chooses a display; with `display1` absent there is
nothing to move to, and it stays on `display0`. Whether it tries and fails, or
never tries without the second framebuffer, is open (see below).

### Rotation

`display.rotation` to 90° is refused on this guest with *"The device did not
apply the requested rotation"*, for the home screen, Settings and Safari, at
0° and 180° of fold, and with the hinge sensor cleared. That is the
orientation gate described in
[springboard_orientation_stuck.md](springboard_orientation_stuck.md), not the
hinge.

## Instruction emulation

The A20 Pro userland uses the CSSC scalar instructions (`ABS`, `CNT`, `CTZ`,
`SMIN`/`SMAX`/`UMIN`/`UMAX`). On a host without `FEAT_CSSC` each one traps to
the guest kernel's fallback. Boot completes; app launches are slower. On this
host, tapping Settings took between 4 and 10 seconds to bring it to the
front.

## The 3D model, for whoever works on it next

`DuoModel.usdz` as RealityKit loads it:

- The halves are `half_back` and `half_front`. `half_back` rests turned 180°
  about Y; a fold must compose with that rest pose, not replace it.
- The spine runs along the scene's Y axis; the outer display faces +Z and the
  inner −Z when the phone lies open.
- The inner display is not a mesh of its own: it is material slot 0
  (part `Plane_038`) of the skinned `hinge_rig`, 26 joints, two influences per
  vertex. Its bind pose equals its rest pose, yet its vertices, measured in
  the entity's space, come out mirrored across the panel from where they are
  drawn. A screen is never seen mirrored, so the mapping is checked with
  `u × v` against the panel's outward normal and reflected back when it
  disagrees.
- Emissive textures on `PhysicallyBasedMaterial` showed a flat colour on
  this host; an `UnlitMaterial` shows the frame, and is what a screen should
  be anyway.
- The exported scene lost its button hit zones (they were hidden in Blender
  and USD export skipped them); the app builds zones from the key meshes.

## Open questions

- **Does SpringBoard try to switch to `display1`?** Its fold transition and
  the pose provider's decision would show at the debug log level, or with a
  breakpoint on the pose provider's update path.
- **Is CoreMotion's notifier running?** `CLLidAngleNotifier` instantiated
  through vphoned's script bridge, with a handler logging what it receives,
  would show whether the angle gets past the HID service today.
- **Could one framebuffer stand in for both?** Answering `display1`'s
  geometry from the one VM display, and switching what it shows by pose, is
  the path to a guest that relays out on unfold. It needs SpringBoard's
  display arbitration and the framebuffer's identity, both unexplored.

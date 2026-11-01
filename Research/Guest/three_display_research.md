# Three simultaneous displays: current boundary and remaining paths

## Scope and date

This note continues the iPhone Duo work on 2026-10-24. The target is three
simultaneously active guest displays. It does not reopen runtime screen-size
switching or the already completed fold-posture and Preboot subtype work.

## Evidence from the host frameworks

The current VM uses `VZMacGraphicsDeviceConfiguration` and one
`VZMacGraphicsDisplayConfiguration` in
`VPhoneExecutable/VPhoneVirtualization/UI/VirtualMachine/VPhoneVirtualMachine.swift`.
The macOS 27.0 SDK documents the public `displays` property as **maximum of one
display**.

The lower-level `ParavirtualizedGraphics.framework` has a different contract:

- `PGDeviceDescriptor.displayPortCount` defaults to 1 and accepts values from 1
  through `PGMaxDisplayPortCount()`.
- `PGMaxDisplayPortCount()` returned **8** on this Mac (macOS 27.0.1, build
  26A434).
- `PGDevice.newDisplayWithDescriptor:port:serialNum:` creates one display per
  configured port; releasing the object simulates hot-unplug.
- The PG display API supplies mode changes and guest compositor frames to the
  host application, so it is a real multi-display device API rather than a
  host-window duplication API.

Runtime reflection against the installed Virtualization framework found the
private `VZMacGraphicsDeviceConfiguration` property and setter
`_displayPortCount` / `_setDisplayPortCount:`. A standalone probe set the value
from 1 through 8 successfully on the configuration object. That only proves the
object accepts the request; it does not prove that VZ's VM service will create
such a device.

The same probe, when given the virtualization entitlement, reached the host
availability check. The existing live experiment already established the next
check: on ordinary macOS, VZ's system service rejects a Mac graphics device with
more than one display port. Apple's own VM service contains the corresponding
one-port restriction. This is why changing the deleted experiment back to two
or three `VZMacGraphicsDisplayConfiguration` entries is not a solution.

## What remains technically possible

### 1. Own the PGDevice path

This is the only path that preserves Apple's paravirtual display protocol and
has a host API designed for several ports. A future implementation would need
to create a `PGDeviceDescriptor` with `displayPortCount = 3`, create three
`PGDisplay` objects, and connect the device to the VM's guest physical memory,
MMIO and interrupt lifecycle. It would also need to provide frame handling and
mode-change handling for each display and integrate suspend/resume correctly.

The public VZ API exposes no attachment point for a caller-owned `PGDevice`.
`VZMacGraphicsDeviceConfiguration` constructs and owns the device inside the VZ
system service. Replacing that object therefore means taking over the graphics
portion of the VM service boundary, not adding another Swift configuration
object. This is a high-risk research direction and will likely require private
VZ interfaces or a replacement VM stack.

### 2. Use Virtio GPU scanouts

The VZ 27.0 SDK also documents `VZVirtioGraphicsDeviceConfiguration`, but its
public contract says **maximum of one scanout**. More importantly, the iOS guest
in this project is wired to Apple's `AppleParavirtDisplay` protocol and the
existing kernel display patches. A Virtio GPU device would require a different
guest driver and display stack; adding scanouts to the host configuration would
not make the current iOS display driver consume them.

This route is therefore a new guest display-driver project, not a continuation
of the current VZ display configuration.

### 3. Patch Apple's VZ system service

The private `_setDisplayPortCount:` setter is a useful probe point, but the
one-port decision is enforced after configuration reaches Apple's system XPC
service. Patching or interposing that service would cross the trust boundary
of a system process and would need to keep its device serialization, entitlement
checks, suspend/resume state, and PG display ownership coherent. It is the most
fragile option and has no current success evidence.

## Current conclusion

Three simultaneous displays are not blocked by the PG protocol itself: the host
framework advertises up to eight ports. They are blocked by the VZ Mac graphics
configuration and its ordinary-macOS system-service policy, while the guest
side only understands AppleParavirtDisplay. The next useful experiment is a
read-only inventory of the VZ-to-PG object and XPC boundary, followed by a
minimal standalone PGDevice lifecycle probe. No VM configuration, guest disk,
firmware patch, or running test machine should be changed until that probe can
create and drive one PG display outside VZ.

The existing fold posture RPC, `V68VM2025` Preboot repair, X1 work, and
VirtualAudio work remain independent and are not changed by this research.

## Hinge animation versus screen unfolding

The current `display.posture` path already exercises one piece of animation. A
posture change is accepted by `SBSTestAutomationService`; SpringBoard logs
`hinge MOTION STARTED` and then `hinge SETTLED` (about 1.03 seconds in the live
Duo run). That is SpringBoard's internal transition around a synthetic pose,
not a continuously driven hinge angle.

The RPC input cannot currently carry a continuous angle. It carries one of five
hinge states, and SpringBoard derives the angle from that state using the fixed
mapping `ambiguous=0`, `closed=0`, `partially-open=90`, `open-flat=180`,
`open=180`. Repeating calls with intermediate values would only replay those
discrete states and could race the settle state machine; it would not produce a
real 0–180 degree sensor stream.

A real angle animation would need a guest-side CoreMotion input path for the
hinge-angle HID event (`IOHIDEventCreateHingeAngleEvent`, the virtual service
identified during the earlier run as `0xFF0C/0x21`) and the companion device-state
HID event. That path is currently behind the same two prerequisites already
observed: V68 product capability recognition and
`FBDisplayManager.alwaysConnectedIdentities.count >= 2`. Until those are true,
CoreMotion does not become the source of SpringBoard's fold pose, so adding a
virtual hinge event alone does not unlock animation.

Screen unfolding has a separate hard gate. SpringBoard needs two always-connected
display identities before it can publish the foldable display modes. The current
guest has one AppleParavirtDisplay scanout, so every pose—including `open-flat`—
keeps the same single outer screen. `V68VM2025` only makes pose persistence
work across launch and display-mode transitions; it does not create a second
identity or a second scanout.

Therefore a host-side animator can at most demonstrate SpringBoard's existing
discrete motion transition. It cannot demonstrate screen unfolding. The next
meaningful experiment is to create two PG display identities in a standalone
PGDevice probe and then inspect whether the guest's AppleParavirtDisplay path
can expose both identities. If that probe cannot reach the guest, the remaining
work is a guest display-driver or SpringBoard/FrontBoard compatibility project,
not an RPC change.

A first standalone PGDevice lifecycle probe was attempted on the M5 Pro. The
host reports Metal support through `system_profiler`, but a command-line process
in this sandbox received a nil `MTLCreateSystemDefaultDevice()` and consequently
`PGCreateDeviceWithDescriptor` returned nil. This is an environment limitation,
not evidence that PGDevice itself cannot be created; the probe must be rerun from
a GUI-hosted, properly signed process before the PG route is judged.

The GUI-hosted retry did not reach PG initialization: LaunchServices rejected the
minimal temporary app with `kLSNoExecutableErr (-10827)`. The temporary probe was
outside the repository and was removed after the attempt; no shipped target was
changed.

## VZ service check through the real CLI (2026-10-24)

The disposable `duotest-fold` machine was stopped, bound through
`vphone-launchpad-cli vm set-bundle`, and its guest environment was updated
through the same CLI. A bundle build with the private setter and two configured
`VZMacGraphicsDisplayConfiguration` objects reached the real VM launch path and
logged:

```text
[vphone] Experimental display ports requested: 2
[vphone] Fatal: Error Domain=VZErrorDomain Code=2
  "显示器端口数量无效，必须介于1和最大支持数量之间。"
```

The failure occurs before boot and before any guest or lock-screen state is
involved. It confirms on the actual VZ service used by vphone that the ordinary
host's effective maximum is one port, despite the lower-level PG header exposing
`PGMaxDisplayPortCount() == 8`. The experiment did redeploy the experimental
guest environment before the launch attempt, but changed no firmware or boot
chain state. The machine was stopped after the failed launch and restored to its
original Core Bundle through the CLI.

The restored machine then passed the baseline control path through
`vphone-launchpad-cli`: `vm start --wait` reached vphoned after 5 seconds,
`guest unlock` returned `locked=false` and `screen_off=false`, and two posture
calls returned `{hinge:2, orientation:1, tabletop:0}` and
`{hinge:3, orientation:1, tabletop:0}`. `vm stop` completed cleanly. These
calls prove the existing discrete posture RPC still works after the controlled
VZ rejection test; they do not establish a second display.

## Runtime hot-plug probe (2026-10-24)

A second disposable Bundle kept the initial VZ configuration at one display and
called the private runtime `_attachDisplay:completionHandler:` after VM start.
The detached display object was created with `VZMacGraphicsDisplay._initDetached`
and its private `_configuration` ivar was populated from a second
`VZMacGraphicsDisplayConfiguration`. The probe reached the VM start path and
recorded `requested=2;graphics=1`, but neither the attach completion nor the
post-call marker was emitted. The guest itself continued far enough for
`vphoned` to answer, while the host attach call did not produce a second runtime
display. The probe Bundles were removed from the machine binding and installed
Bundle store afterward.

This closes both VZ entry points available without replacing Apple's system
service: two ports at initial configuration are rejected synchronously, and
runtime hot-plug does not return a usable second display.

## In-process PGDevice probe (2026-10-24)

The PG probe was then moved into the real `vphone-vm` process, after the VM had
started and the process had a valid GUI/Metal context. `MTLCreateSystemDefaultDevice`
returned `Apple M5 Pro`, but `PGCreateDeviceWithDescriptor` still returned nil.
Populating the descriptor's `raiseInterrupt` callback did not change the result.
The probe therefore did not reach `PGDisplay` creation, even outside the VZ
configuration object. This is the strongest current evidence that direct PGDevice
creation is unavailable to this process on the production macOS/VZ setup, likely
because the PG device is reserved for Apple's virtualization service boundary.

The machine was restored to `2.12.0-local.20d9f856` and stopped after the probe;
temporary probe Bundles were removed through `vphone-launchpad-cli`.

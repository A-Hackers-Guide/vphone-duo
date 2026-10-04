# Turning the screen on and unlocking

vphoned's `screen.unlock` (`VPhoneDaemon/Daemon/GuestScreenUnlock.swift`,
`VPhoneDaemon/Native/vphoned_unlock.m`) and `vphone-launchpad-cli guest unlock`.
Measured on 2026-10-04 against `unlocktest-iphone` (iPhone17,3, iOS 27.0
24A435, no passcode), with the 26.6.2 dyld shared cache for the static read.

## Why a method

A guest is at the Lock Screen after every boot, every SpringBoard restart and
every press of the side button, and it is dark a few seconds later
(`lock_screen_idle_timer.md`). A locked or dark screen swallows taps, and
`apps.launch` answers `device_locked`.

The hardware keys only toggle. `power` wakes a dark guest and darkens a lit
one; `home` wakes, and on a lit Lock Screen without a passcode it dismisses to
the Home Screen. A script has to read `device.screen` first and choose. The
method does that reading and does only what each state needs.

## What SpringBoard's own unlock request does, and why it is not used

SpringBoardServices has `-[SBSLockScreenService
requestPasscodeUnlockUIWithOptions:withCompletion:]` (`0x191f505c8` in the
26.6.2 cache), the request an app makes when it needs an unlocked device.
Served to a caller with `com.apple.springboard.requestDeviceUnlock` (the
authenticator in `-[SBLockScreenService init]` is built with that entitlement
string, at `0x224be0ae4`).

Granting vphoned that entitlement and calling the request was tried first. The
guest log shows why it does not unlock a passcode-free device:

```
unlockUIFromSource:ExternalRequest options:({SBUIUnlockOptionsTurnOnScreenFirstKey: 1}) screenWasOff:YES
Bailing from UIUnlock because: turnOnScreenFirst = 1; autoUnlock = 0; shouldTurnOnScreen = 1
```

Asked while the screen is off, SpringBoard treats the request as *turn the
screen on first*: it lights the backlight and bails out of the unlock
(`autoUnlock = 0`), leaving the Lock Screen up. A second request, with the
screen now on, did not dismiss it either. The request is the wrong tool for a
passcode-free guest, and it needs a private entitlement. Both were dropped.

## What `screen.unlock` does

1. Reads `com.apple.springboard.lockstate` and
   `com.apple.springboard.hasBlankedScreen` (IcliKit's `lockState()`). Until
   `com.apple.springboard.finishedstartup` is non-zero these read
   "unlocked, lit" no matter what will show, so at startup it waits for that
   notification before trusting them.
2. Not locked, only dark: `SBSUndimScreen`, and done. This lights the display
   with no toggle and needs no entitlement (it is what icli's `wake` calls).
3. Locked: if dark, `SBSUndimScreen` first so the next step lands on a live
   Lock Screen. Then press Home.
   - No passcode: Home dismisses the Lock Screen. Repeated until unlocked or
     the deadline, in case the first press landed while the display was still
     coming up.
   - Passcode: Home raises the passcode pad; `passcode` is typed (digits as
     keyboard number keys `0x1E`–`0x27`, anything else as text), with Return
     if the pad has not submitted after a second.
4. Polls the two notify states every 100 ms until lit and (if it was locked)
   unlocked, or `timeout` (10 s by default, 1–60) runs out.

Result: `{locked, screen_off, was_locked, was_screen_off}`; capability
`screen_unlock`. No private entitlement.

## Live results (no-passcode guest)

All on `unlocktest-iphone`, each followed by `device.screen` and
`apps.foreground`:

| State before | `guest unlock` | After |
| --- | --- | --- |
| just booted, dark Lock Screen | ok, `was_screen_off:true was_locked:true` | Home Screen, lit |
| lit, unlocked | ok, all `false` | unchanged |
| `power` → dark + locked | ok | Home Screen, lit |
| same, repeated | ok | Home Screen, lit |
| lit Lock Screen (`was_screen_off:false`) | ok | unlocked; `apps.launch` Settings then `frontmost_verified:true` |
| after `system.respring` → Lock Screen | ok | Home Screen, lit |

So the device is actually usable afterwards, not merely reporting unlocked.

## Not yet measured

- **Passcode guests.** Setting a passcode on a research guest is not
  automated, so the Home-raises-the-pad-then-type path is unrun. It is written
  to the behavior of a real device (Home/menu raises passcode entry); treat it
  as untested until a passcode guest is available.
- iPadOS, and iOS 27.0.1 (its guests kernel-panic at first boot, separate
  issue).

## Reproducing

```sh
vphone-launchpad-cli guest send <vm> '{"t":"key","name":"power","screen":false}'   # dark + locked
vphone-launchpad-cli guest rpc  <vm> device.screen                                 # locked, screen_off
vphone-launchpad-cli guest unlock <vm>
vphone-launchpad-cli guest rpc  <vm> device.screen
vphone-launchpad-cli guest rpc  <vm> apps.foreground
```

The `Bailing from UIUnlock` evidence, if the request path is revisited:

```sh
vphone-launchpad-cli guest rpc <vm> logs.syslog '{"seconds":8,"process":"SpringBoard","max_lines":5000}'
```

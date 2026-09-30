# Skipping Setup Assistant on an activated guest

Device › Skip Setup Assistant… and vphoned's `setup.status` / `setup.skip`
(`VPhoneDaemon/Daemon/GuestAPI+SetupAssistant.swift`) rest on the experiments
below, run on 2026-09-30 against `test-26.4` (iOS 26.4, already activated)
over `vphone.sock` with `settings.get/set/delete`, `system.respring`,
`processes.list` and screenshots.

## Where the state lives

Setup.app keeps its state in the `com.apple.purplebuddy` domain for user
mobile (`/var/mobile/Library/Preferences/com.apple.purplebuddy.plist`). The
key names are SetupAssistant.framework exports that Setup.app imports:

| Export | Key |
| --- | --- |
| `BYBuddyDoneKey` | `SetupDone` |
| `BYBuddyFinishedInitialRunKey` | `SetupFinishedAllSteps` |
| `BYBuddyIOSVersionKey` | `SetupVersion` |
| `BYBuddyLastExitKey` | `SetupLastExit` |
| `BYBuddyIOSCurrentVersion` | the current `SetupVersion`, an `int32` (Setup.app loads it with `ldr w2`); 11 on 26.4 and 27.0 |

A finished guest also carries `*Presented` pane flags, `*MiniBuddy*Ran`
flags, `Language`, `chronicle` and Setup's own `lastPrepareLaunchSentinel`.
No `/var/Managed Preferences/mobile/com.apple.purplebuddy.plist` override
exists on these guests.

## What each key does

Each row changes one thing from a finished guest, then restarts SpringBoard
(`system.respring`) and unlocks.

| Change | Result |
| --- | --- |
| delete `SetupDone` | full Setup (“hello”) before the Lock Screen |
| delete `SetupFinishedAllSteps` | Home Screen; Setup does not run |
| delete `SetupVersion` | the flow after a software update, after unlocking (“外观” pane, or straight to “软件更新已完成” when every `*Presented` flag is set) |
| `SetupVersion = 11` again | Home Screen |
| delete every key in the domain | full Setup; Setup writes only `lastPrepareLaunchSentinel` on launch |
| from that empty domain, set only `SetupDone`, `SetupFinishedAllSteps`, `SetupVersion = 11` | Home Screen after the restart, again after a second restart and a 25 s wait; no later panes |

## When SpringBoard decides

SpringBoard decides whether to run Setup once, when it starts.

- Setting `SetupDone = true` while Setup is on screen does not dismiss it.
  Setup switches to its “software update finished” pane, and the idle timer
  now applies, so the screen locks.
- Killing Setup then only makes SpringBoard launch it again (“hello”, swipe up
  to open).
- Restarting SpringBoard with the keys in place goes to the Lock Screen and
  then the Home Screen.

So a skip is: write the three keys through cfprefsd, then restart
SpringBoard. The write has to go through cfprefsd (`CFPreferencesSetValue`
for user mobile, then synchronize). Editing the plist file directly leaves
cfprefsd holding the old values.

## Detection

`setup_pending` in `/v1/health` is `SetupDone != true || SetupVersion <
BYBuddyIOSCurrentVersion`: two cfprefsd reads per probe. `setup.status` also
reports whether `/Applications/Setup.app/Setup` is running.
`apps.foreground` is not a usable signal. On `test-27.0` it reported
SpringBoard with `source: unavailable` while an app was in front.

## Not covered

- Mini flows triggered by other keys (`*MiniBuddy*Ran`, missing `*Presented`
  flags on a later build) are not detected or skipped. None appeared with
  only the three keys set.
- The skip does not check activation. On an unactivated guest SpringBoard
  still needs activation.
- MCInstall `SetCloudConfiguration` with `SkipSetup` keys, which
  pymobiledevice3 `profile supervise`, go-ios `prepare` and `cfgutil prepare`
  use, applies only to an erased device. The device refuses a second
  configuration (error 14002), so it does not fit a guest that is already
  set up or activated.

## Returning a guest to Setup Assistant

To see Setup again for testing, delete `SetupDone` with `settings.delete` and
restart SpringBoard. Delete `SetupVersion` instead to see the flow after a
software update. Save the domain first with `settings.get`, because deleting
every key loses the pane flags and `Language`.

# Trimming system services

vphoned's `trimmed` service profile turns off about 140 launchd jobs a
research VM has no use for: Siri and the intelligence daemons, Find My,
Wallet/NFC/Secure Element, Watch, Home, health coaching, Maps background
work, iCloud and iMessage sync, ads and recommendations, telemetry, accessory
firmware updates and OTA. On an iOS 27.0 guest that cuts process memory by
29%, idle host CPU by 26% and idle host writes by 60%, and no vphone feature
was lost. The profile is applied once, in the setup boot of a machine
template, and every clone of the template inherits it.

`services.profile` and `services.profile.apply` are described in
[`vphoned_http_api.md`](../vphoned_http_api.md); the lists are in
`VPhoneDaemon/Daemon/GuestServiceProfile.swift`.

## How it works

The profile uses the override `launchctl disable` writes, which lives in
launchd's database on the data volume
(`/private/var/db/com.apple.xpc.launchd/disabled.plist`). launchd does not
load a disabled job at the next boot. It is the same mechanism
`services.disable` and the [OTA block](ota_software_update_block.md) use.

- **It takes a reboot.** `services.stop` and `services.unload` answer with
  launchd status 144 on the guest, so a running job keeps running until the
  guest restarts.
- **It is not a firmware patch.** The system volume and `launchd.plist` are
  untouched, nothing goes into a patch set, and the Services panel still lists
  every job, disabled ones marked as such.
- **It reverts cleanly.** vphoned records the labels it disabled in
  `/var/db/vphoned/service-profile.plist`. `profile: "none"` turns back on
  those labels and no others. A job that was already disabled when the profile
  ran, such as the OTA trio, is never recorded and stays disabled.
- **The host has to ask.** The host cannot write the data volume of a guest:
  it is encrypted with the guest's keys. So the profile is applied by vphoned
  from inside the guest.

## What `trimmed` disables

| Group | Default | Labels | Why they can go |
| --- | --- | --- | --- |
| `base` | on | 137 | Appendix A of the measurement below. Nothing in vphone, IcliKit or the guest hooks talks to them |
| `app_store` | on | `com.apple.appstored`, `com.apple.itunesstored` | Off with the App Store and iTunes Store apps a template removes. `appstorecomponentsd` is already in `base` |
| `signin_followup` | on | `com.apple.followupd`, `com.apple.appleidsetupd` | The sign-in follow-up and Apple Account setup prompts. They complement `libsigninfix`'s pane suppression. A guest that went through `setup.skip` has no follow-up items, so no orphaned badge is left |
| `accounts` | off, `groups: ["accounts"]` | `com.apple.akd`, `com.apple.amsaccountsd`, `com.apple.appleaccountd` | Only for guests that never sign in: with these off, the guest cannot sign in to an Apple Account |

The `base` group, by area:

| Area | Examples | Kind |
| --- | --- | --- |
| Siri and intelligence | assistantd, siriinferenced, intelligenceflowd, siriactionsd, modelmanagerd, corespeechd | Not used. siriactionsd also serves Shortcuts and App Intents, and corespeechd and modelmanagerd serve dictation |
| Photos and media analysis | mediaanalysisd, photoanalysisd, photosface | mediaanalysisd alone wrote 79 MiB in a 15-minute idle window |
| Ads, content and recommendations | amsengagementd, promotedcontentd, tipsd, weatherd, gamed | amsengagementd was the top idle CPU and write consumer |
| Find My | findmydeviced, searchpartyd, findmylocated, fmflocatord | No Apple Account |
| Wallet, NFC, Secure Element | passd, nfcd, seld, seserviced, coreidvd | No NFC or SE hardware |
| Watch | nanotimekitcompaniond, nanoprefsyncd, nanobackupd | No paired watch. nanoregistryd stays (see below) |
| Home and health | homed, homeeventsd, fitnesscoachingd, ThreadCommissionerService | HomeKit apps under test need `homed` |
| Maps background | routined, navd, destinationd, mapspushd, mapssyncd | Not the location simulation path |
| iCloud, iMessage, mail sync | identityservicesd, imagent, maild, remindd, replicatord, syncdefaultsd | No account. Mail, Reminders and iMessage under test need theirs |
| Telemetry | analyticsd, triald, cloudtelemetryd, hangtelemetryd and other reporting daemons | Upload only. ReportCrash and osanalyticshelper stay, for `logs.crashes` |
| Accessory firmware | accessoryupdaterd, uarpd and helpers | No accessories. accessoryupdaterd used 18 s of CPU at boot |
| OTA | softwareupdateservicesd, mobile.softwareupdated, OTATaskingAgent, OTACrashCopier | Same as the [OTA block](ota_software_update_block.md) |
| Cellular extras and prediction | WirelessRadioManager, carkitd, vmd, PowerUIAgent, duetexpertd, ospredictiond | CommCenter itself stays |

Some of these are only optional: Shortcuts, dictation, HomeKit, Maps,
Mail, Reminders, iMessage and Safari bookmark sync. A research target that
uses one of those frameworks needs its daemon back. Pass that label in `allow`
and apply again; the profile turns back on a recorded label it no longer
selects.

Only iOS 27 has a list. It was measured on an iPhone guest. An iOS 26 or
iPadOS guest gets "No trimmed service list" until one is measured there.

## Never disabled

`GuestServiceProfile.neverDisable` lists what the profile refuses to disable,
whatever list or group names it. Four kinds of job were measured to make the
guest **worse** when off, and are kept out of the lists for that reason:

| Job | What happens without it | Evidence |
| --- | --- | --- |
| `com.apple.sleepd` | SpringBoard's and mobiletimerd's HealthKit sleep clients (`HKSPXPCConnectionProvider`) reconnect to `com.apple.sleepd.sleepserver` with no back-off | 5000 log lines in 3 s, host at about 400% CPU, launchd used 115 s of CPU and wrote 385 MiB in the first two minutes |
| `com.apple.CommCenter`, `CommCenterMobileHelper`, `CommCenterRootHelper` | SpringBoard's `SBTelephonyManager` reconnects to `com.apple.commcenter.xpc` every second and resets the idle timer each time (`updateIdleTimerForReason:"TelephonyManager:UpdateSB"`), so **the screen never turns off** | A 1 Hz loop in the log; backboardd grew from 99 to 160 MB; SpringBoard took 4418 wakeups in two minutes |
| `com.apple.cloudd` | transparencyd (`Retrying CK account state fetch`) and ScreenTimeSettingsAgent keep retrying CloudKit | Each wrote 50–60 MiB per 15 idle minutes, against nothing on the untrimmed guest. Idle writes rose above the untrimmed guest's, to 337 MiB per 15 minutes |
| `com.apple.nanoregistryd`, `nanoregistrylaunchd` | locationd waits synchronously on NanoRegistry's management queue | A spindump of a hung locationd showed `com.apple.nanoregistry.registry.managementqueue` in `dispatch_sync`. 27.0's locationd also hangs and crashes on its own, so this is kept out of caution |

The rest of the list is what vphone's own features and the tools it drives
rely on. Each one was traced to vphoned, IcliKit, the guest hooks or a
research note: SpringBoard, backboardd, runningboardd, lsd,
containermanagerd, installd, misagent, lockdownd, remoted, cryptexd,
remotepairingdeviced, avconferenced, diskimagesiod, locationd, bluetoothd
(locationd calls it synchronously), pasted, powerd, amfid
(`com.apple.MobileFileIntegrity`), profiled, keybagd, cfprefsd, notifyd,
mDNSResponder, configd, timed, tzlinkd, securityd, logd, diagnosticd,
ReportCrash, osanalyticshelper, audiomxd, mediaplaybackd, mediaremoted,
cameracaptured, mobileactivationd, mobileassetd and storekitd (which the OTA
and App Store notes require), and vphoned itself. dtremotedisplayd and
dtdeviceinfod are not launchd.plist jobs on 27.0 and are out of reach anyway.

Two jobs looked like candidates and cannot be disabled this way.
`com.apple.siri.context.service` and `com.apple.siri.acousticsignature` are
XPC services, not LaunchDaemons, so the override is written and they run
anyway.

## Measurements

These numbers come from `svctest-a`, a `--new-identity` clone of an iPhone
27.0 (24A435) guest with cloudOS 26.4, 8 GB and 8 cores, started `--headless`
after `setup.skip` (2026-10-07). Both runs used the same machine and disk. The
baseline is its third untrimmed boot. Host figures are `proc_pid_rusage` of
the VM process every 10 s. Guest figures come from `processes.list`,
`memory.jetsam` and `/usr/bin/taskinfo`, run through a one-shot launchd job.

| After 17 minutes idle | Untrimmed | Trimmed (137 + store) | Change |
| --- | --- | --- | --- |
| Guest process footprint, summed | 1658 MB | 1177 MB | −29% |
| Processes | 394 | 263 | −33% |
| `memorystatus_level` (free memory) | 62% | 73% | |
| Host VM process CPU, idle window | 6.5% of a core | 4.8% | −26% |
| Host writes, 15 idle minutes | 220 MiB | 89 MiB | −60% |
| Host writes, first 100 s of boot | 572–604 MiB | 363–423 MiB | about −35% |
| Host VM process footprint | 8.67 GB | 7.26 GB | |

Boot CPU varied more between runs (72–208 s in the first 100 s untrimmed,
44–138 s trimmed) than trimming changed it, so only the drop in boot writes is
dependable. vphoned answered 5–14 s after start either way, because launchd
starts it early. The host keeps most of the memory the guest frees, since the
VM has no balloon device. The gain is headroom inside the guest.

A template set up with the profile (P0, 2026-10-07) showed the same effect on
its clones. A clone's first 100 s wrote 372–375 MiB, against 1040 MiB for a
clone of an unprepared template.

### Function checks

These checks gave the same result trimmed and untrimmed: unlock, screenshot,
`apps.list` (258), installing a small app with `apps.install` and launching it,
Settings, clipboard, `audio.state`, starting the Camera app, uninstalling.
SpringBoard kept the same pid through every run, and no new crash type
appeared.

Not checked:

- installd's own install path (`ideviceinstaller`).
- Xcode and DeviceHub screen viewing. The jobs they need are kept.
- Frida.
- A real microphone path.
- **Location.** 27.0's locationd hangs or crashes with `EXC_ARM_PAC_FAIL` on
  untrimmed guests too, and Location Services were off after `setup.skip`.
  Test it again on a trimmed guest once locationd is fixed. Until then, the
  Maps background group and `nearbyd` are only optional, not unused.

Known side effect: with `weatherd` off, the default Home Screen's Weather
widget reads "Weather Unavailable". Pass `allow: ["com.apple.weatherd"]` to
keep it.

## Applying it in a template

A template is changed once, in its setup boot, and frozen; every clone
inherits the overrides and the record. The order matters:

1. `setup.skip`.
2. `setup.settle`, until first-boot app expansion is done.
3. Remove the system apps.
4. `services.profile.apply {profile: "trimmed", force: true}`. The
   `signin_followup` group belongs after the first-boot work, which step 2
   already waited for. Every override waits for the reboot anyway, so one call
   covers both the services and the sign-in follow-up.
5. Reboot, and check that no job the profile owns is running
   (`services.profile` → `running` empty).
6. Shut down and freeze.

## Reverting

On a running guest:

```sh
vphone-launchpad-cli guest rpc <vm> services.profile.apply '{"profile":"none","force":true}'
vphone-launchpad-cli vm stop <vm> && vphone-launchpad-cli vm start <vm> --wait
```

That turns back on only what the profile disabled. To keep the profile but
bring back one job, apply `trimmed` again with that label in `allow`. To
bring back the Apple Account daemons on a guest that had `accounts`, apply
`trimmed` without that group.

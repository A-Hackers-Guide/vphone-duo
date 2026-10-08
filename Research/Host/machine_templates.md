# Machine templates

A template is a complete machine that boots once, for its setup boot, before
it is frozen, and never after. New machines are cloned
from it with `clonefile(2)` and a new identity (see
[machine identity and clone](machine_identity_and_clone.md)), so a second
machine for the same firmware costs a clone and a few hundred MB of first-boot
writes instead of a 20 GB restore. User-facing behavior is in
[Create and run](../../Documents/Guides/create-and-run.md#templates).

Code: `VPhoneKit/VPhoneCoreKit/Bundle/VPhoneMachineTemplateKey.swift` (the key,
pure), `VPhoneMachineTemplates.swift` (storage, freeze, adopt, clone, boot
refusal), `VPhoneTemplateSlimmingRequest.swift` (switches to slimming),
`VPhoneTemplateSetupBoot.swift` (the setup boot's steps, against a
`VPhoneTemplateSetupMachine`),
`VPhoneExecutable/VPhoneCommand/VPhoneCommand/VirtualMachine/VPhoneMachineTemplateKeys.swift`
(resolving a key from options or from a machine's records),
`VPhoneTemplateSetup.swift` (the switches, the `vphone-vm` the setup boot
drives over `vphone.sock`), `VPhoneVirtualMachineCreator.swift` (`vm create`)
and `VPhoneVirtualMachineTemplateCommand.swift` (`vm template`). Tests:
`VPhoneKit/VPhoneCoreKitTests/Bundle/MachineTemplate*Tests.swift`,
`TemplateSlimmingRequestTests.swift`, `TemplateSetupBootTests.swift` (the
step machine against a scripted guest).

## Key

Everything a clone inherits and could not change without a restore:

| Field | Source for a create | Source for `adopt` |
| --- | --- | --- |
| device | `VPhoneIPSWCache.guestDevice` of the iPhone IPSW (and `--device`) | `config.plist` `guestProductType` |
| iOS version and build | iPhone IPSW `BuildManifest` | `restore-info.json` `ios` |
| cloudOS version and build | cloudOS IPSW `BuildManifest` | `restore-info.json` `cloudOS` |
| preset | `--preset` | `PatchPlan.plist` `Preset` |
| boot-chain plan digest | the preset resolved against the two versions | `PatchPlan.plist` `EnabledPatches`, `Parameters` |
| bundle series | this `vphone-cli`'s `Info.plist` | `launchpad.json` `bootChain`, else the `Guest` receipt part when `cfw install` wrote it, else this `vphone-cli` |
| disk size (decimal GB) | `--disk-size` | `Disk.img` length |
| slimming: trim tier, setup boot, service profile, service groups, removed apps | the slimming switches (below) | `Template.plist` steps `vm template setup` recorded, else nothing done |
| format version | 2 | 2 |

The identifier is the first 12 hex digits of the SHA-256 of one
`name=value` line per field in a fixed order (`canonicalDescription`); a test
pins one value against `shasum`. Any change to what a field means raises the
format version instead, so old templates stop matching rather than matching
wrongly. Format 2 added `service-groups` (P2's format-1 templates, never
booted, list as stale and still serve `--template <id>` with a warning).

The plan digest hashes the sorted identifiers of the enabled patches whose
catalog target is `.firmware(*)` (AVPBooter, iBSS, iBEC, LLB, TXM, kernelcache,
DeviceTree), plus any enabled identifier the catalog does not know (an
external set's, counted to be safe), and the preset's parameters. Guest
patches are left out: `cfw update-environment` applies them to a clone in
either direction. The preset itself is a field because `standard` and
`experimental` also differ in `guest.identity`, which only a full
`cfw install` writes into Preboot.

Not in the key: CPU, memory, screen, network, unlock at startup. They are
`config.plist` settings that `vm create` sets on the clone.

A machine Launchpad created with per-patch overrides has a digest of its own,
so it never serves a create without them. A template's staleness check
re-resolves with the template's own `PatchSelection.plist`.

## Storage

```
<library>/.templates/
  <id>/                       frozen template: a machine folder + Template.plist
  .building-<id>-<uuid>/<id>/ a build in progress, or one that failed
  .lock-<id>                  flock(2) held while <id> is built
```

- Same volume as the machines, so a clone is a `clonefile`; hidden, so
  `VPhoneLibrary.scan` (`.skipsHiddenFiles`) and with it `vm list` and
  Launchpad never list a template.
- `Template.plist`: `Identifier`, `Key`, `Created`, `BuiltWithBundleVersion`,
  `BootChainBundleVersion`, `SourceMachine` (the name a derived mDNS name
  follows from), `Frozen`, `FrozenAt`, `Steps` (`SnapshotDeleted`,
  `SetupDone`, `ServiceProfile`, `ServiceGroups`, `RemovedApps`, `TrimTier`).
- A build happens in `.building-<id>-<uuid>/<id>/` and is frozen by writing
  `Frozen = true` and one `renamex_np(RENAME_EXCL)` to `.templates/<id>`. A
  listed template is always complete; a race with another build of the same
  key fails the rename and leaves the build unfrozen.
- `freeze` and `adopt` refuse unless `Steps` produced the slimming the key
  promises.
- A clone drops `Template.plist`, `Snapshots/` and `vphone.sock`.

## Never booting once frozen

The P0 measurement: booting a template after clones exist raised one clone's
private bytes from 0.42 GB to 0.80 GB, and every later clone would inherit
that boot's state. Three layers keep a frozen template from booting:

1. `VPhoneLibrary.bundle(named:)` accepts only a machine name (one component,
   no leading `.`), so no verb taking a machine name reaches `.templates`.
2. `vm launch` checks `VPhoneMachineTemplates.requireBootable`.
3. `VPhoneBootCommand.validate`, which `vphone-vm` runs on its arguments,
   checks it too, DFU included: a folder directly in `.templates`, a frozen
   record, or an unreadable one is refused. A machine in a staging folder may
   boot; the setup boot runs there.

A staging machine's control socket,
`<library>/.templates/.building-<id>-<uuid>/<id>/vphone.sock`, is about 125
bytes for `~/.vphone/machines`, past the 104 bytes of `sun_path`.
`VPhoneUnixSocket.withAddressablePath` binds (in `vphone-vm`) and connects
(`VPhoneUnixSocket.connect`, so every host client) through a symbolic link to
the socket's folder inside a fresh 0700 folder under `/tmp`, removed right
after; the kernel follows the link, so the socket is the one at the long path.

## Slimming switches

`VPhoneTemplateSlimmingRequest.resolve()` maps the switches of `vm create`
and `vm template setup` to the key's slimming:

| Switches | trim | setup boot | services | groups | removed apps |
| --- | --- | --- | --- | --- | --- |
| none (`--slim on`) | `defaultTrimTier` (`none` until offline trim lands) | yes | trimmed | none | list C (10 apps) |
| `--slim off` | none | yes | none | none | none |
| `--service-profile none` | default | yes | none | none | list C |
| `--remove-apps off` | default | yes | trimmed | none | none |
| `--keep-apps a,b` | default | yes | trimmed | none | list C minus a, b |
| `--accounts-off` | default | yes | trimmed | `accounts` | list C |

List C: `com.apple.AppStore`, `Home`, `tv`, `news`, `facetime`, `MobileStore`,
`MobileSMS`, `games`, `findmy`, `Passbook` (P0 and P1 verified each stays
removed across a respring and a reboot on 27.0). Camera stays for camera
passthrough checks; Phone lives on the System volume and vphoned refuses it.
Contradictions are refused, all at once: `--slim off` with any slimming
switch, `--accounts-off` without the trimmed profile, `--keep-apps` naming an
app outside list C or with `--remove-apps off`, an unknown tier or profile.
`--no-template` takes no slimming switch; `--template <id>` takes them only to
check them against the template.

`--slim off` still has a setup boot: skipping Setup and waiting for
first-boot work are not slimming. Without them every clone would start at the
Setup screen and write its own first-boot state (P2 measured 3.2 GB per clone
after seven minutes, P0 0.35 GB with a setup boot). It deletes the orig-fs
snapshot too, which is harmless (CFW's rename and `cfw update-environment`
do not use it) and is what lets an offline trim free its space. The sign-in
follow-up daemons stay on with `--slim off`; a template that went through
`setup.skip` has no follow-up item for them to show (P0).

The services the key promises are fixed per template, although vphoned can
switch the profile on a running machine: a clone of a trimmed template starts
trimmed without a reboot of its own, and `services.profile.apply none` undoes
it on that clone.

## Setup boot

`VPhoneTemplateSetupBoot.run()` drives a `VPhoneTemplateSetupMachine`. The
real one (`VPhoneTemplateSetupVirtualMachine`) starts `vphone-vm` the way
`vm launch` does: `requireBootable` (a frozen template is refused),
`VPhoneBundleActivity.requireStopped`, this bundle's vphoned staged,
`VPhoneBootCommand.validate`; headless for `vm template setup` unless
`--window`, windowed in `vm create` like its first-boot check (the template's
setup boot is the guest's first boot). It talks to vphoned through
`vphone.sock`'s `rpc` verb and reads `guest_error`.

| Step | Calls | Deadline | Passes when |
| --- | --- | --- | --- |
| connect | `ping` every second | 300 s | vphoned answers |
| 0 snapshot | `apfs.snapshot.delete {force}` | 120 s | no `orig-fs.disabled.rn-*` in `remaining`/`after` (none to begin with is fine) |
| a skip | `setup.skip {force}`, any refusal retried | 120 s | `setup_done` |
| b settle | `setup.settle {timeout_s ≤ 110}` repeated | 600 s overall | `settled` |
| c apps | `apps.remove_system {bundle_ids, force}` | 300 s | every app `removed`, `absent` or `unregistered_stale` |
| d/e profile | `services.profile.apply {profile, groups, force}`, `services.profile` | 180 s | no `failed`; the record holds `signin_followup` and the extra groups; followupd and appleidsetupd disabled |
| f reboot | `processes.list` (launchd's `start_time`), `system.reboot {force}` | 300 s | vphoned answers with another launchd start time |
| f verify | `apfs.snapshots`, `setup.status`, `services.profile`, `apps.list`, `ping`, repeated | 120 s | no snapshot, Setup done, the profile recorded with `running` empty, no removed app listed |
| name | `device.name.set {}` | 30 s | (a warning on failure) |
| g stop | SIGINT to `vphone-vm` | 60 s | it exits without "turning it off" (the guest shut down within its 15 s) |

`setup.skip` is retried on any refusal: right after vphoned first answers on
a guest that just finished its first boot, it failed with "Cannot allocate
memory", then for 87 s with "relaunch action ignored and launchd stop failed:
144 Requestor lacks required entitlement" (SpringBoard's restart), before it
went through (p4-src, 27.0, 2026-10-08). The keys it writes are idempotent.

Retries: a call that did not reach vphoned (no socket, guest not connected,
timeout) or that vphoned refused with `retryable: true` or `reason: busy`
(`apfs.snapshot.delete` on EBUSY) is repeated every 3 s until the step's
deadline. Other refusals fail the step, except `apps.remove_system`'s
`remove_incomplete`, whose `results` are read: a template build (key fixed)
fails on any app not removed; a machine to be adopted reports it and leaves it
out of the recorded steps, so the adopted key says what was done.

On any failure the VM is killed, the failure names the step
(`VPhoneTemplateSetupFailure`), and nothing is recorded:
`recordSetupBoot` writes only a complete outcome (`SnapshotDeleted`,
`SetupDone`, `ServiceProfile`, `ServiceGroups`, `RemovedApps`; `TrimTier` is
left to the trim), so `freeze` keeps refusing the build.

The device name: `vphone-vm` pins the guest's name to the machine's name
(`device.name.set`) on every connect, and the pin lives in
`/var/db/vphone/devicename.plist` on the Data volume. Left in place, every
clone would show the template's name (its identifier, or the adopted
machine's name) until its own VM connects, and its first DHCP lease would
carry it (P1). The setup boot clears it last.

Measured on iPhone17,3 27.0 (24A435), 2026-10-08: Launchpad created
`p4-src` (first boot at Setup), `vm template setup p4-src` took 2 min 16 s
(Setup's restart refused for 87 s, settle 25 s, reboot 10 s, stop 4 s), the
image grew from 16.8 to 19.3 GB allocated. Two clones started through
Launchpad came up at the Lock Screen and unlocked to the Home Screen (with
"Trust This Computer?"), Setup done, 249 apps with the ten gone, 141 services
off and none running, no snapshot, device names `p4-a` and `p4-b`. Private
bytes (`ATTR_CMNEXT_PRIVATESIZE`) of each clone: 0.17 and 0.09 GB a minute in,
0.58 GB after seven minutes, against 3.2 GB for P2's never-booted template.
The template's own private bytes were 0.10 GB, the blocks both clones
rewrote. A Time Machine local snapshot counts as sharing, so measure a file
made after the latest one, as these clones were.

## Lifecycle

- **vm create** (default): key from the options and switches → lock →
  restore and `cfw install` into the staging folder (offline file trimming
  belongs inside `cfw install` and records `Steps.TrimTier`) → setup boot →
  recorded key must equal the requested one → `freeze` → clone.
  A setup boot failure leaves the build; `vm template setup .building-…`
  retries it under the lock and freezes it on success.
- **Launchpad** (P5) builds a machine with its step-by-step pipeline, whose
  first boot leaves it running at Setup; it stops it, runs
  `vm template setup <name> [switches]`, then `vm template adopt <name>`,
  then `vm create <name> --template <id> --skip-first-boot` and its own first
  boot. `vm template setup` on a machine writes an unfrozen `Template.plist`
  (key from its records) when it has none, and records the steps there.
- `freeze` and `adopt` refuse a record whose steps did not produce the key's
  slimming.

## Staleness

`vm template list` marks a template stale when any of these holds:

- its series differs from this `vphone-cli`'s (a new series rebuilds);
- its preset no longer resolves, or resolves to another boot-chain digest;
- `FirmwarePatchDrift` finds a boot-chain patch whose receipt part disagrees
  with what the plan wants.

A stale template is never used. Guest-environment updates within a series do
not make a template stale; the clone can take `cfw update-environment`.

## Shared secrets

Every clone of a template shares its SEP root secret, gigalocker, Data/User
volume keys, `mobileactivationd.uuid`, the Data contents the restore wrote and
what the setup boot wrote: Setup done, the keychain items and caches of one
first boot, the removed-app backups and the service record. The setup boot
never pairs a host, signs in or unlocks with a passcode, so no trusted host or
account is shared. `vm create --no-template` builds a machine with secrets of
its own.

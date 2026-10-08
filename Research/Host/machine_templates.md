# Machine templates

A template is a complete machine that never boots. New machines are cloned
from it with `clonefile(2)` and a new identity (see
[machine identity and clone](machine_identity_and_clone.md)), so a second
machine for the same firmware costs a clone and a few hundred MB of first-boot
writes instead of a 20 GB restore. User-facing behavior is in
[Create and run](../../Documents/Guides/create-and-run.md#templates).

Code: `VPhoneKit/VPhoneCoreKit/Bundle/VPhoneMachineTemplateKey.swift` (the key,
pure), `VPhoneMachineTemplates.swift` (storage, freeze, adopt, clone, boot
refusal), `VPhoneExecutable/VPhoneCommand/VPhoneCommand/VirtualMachine/VPhoneMachineTemplateKeys.swift`
(resolving a key from options or from a machine's records),
`VPhoneVirtualMachineCreator.swift` (`vm create`) and
`VPhoneVirtualMachineTemplateCommand.swift` (`vm template`). Tests:
`VPhoneKit/VPhoneCoreKitTests/Bundle/MachineTemplate*Tests.swift`.

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
| slimming: trim tier, setup boot, service profile, removed apps | `none`, no, `none`, none | `Template.plist` steps of a machine still being built, else the same |
| format version | 1 | 1 |

The identifier is the first 12 hex digits of the SHA-256 of one
`name=value` line per field in a fixed order (`canonicalDescription`); a test
pins one value against `shasum`. Any change to what a field means raises the
format version instead, so old templates stop matching rather than matching
wrongly.

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
  `SetupDone`, `ServiceProfile`, `RemovedApps`, `TrimTier`).
- A build happens in `.building-<id>-<uuid>/<id>/` and is frozen by writing
  `Frozen = true` and one `renamex_np(RENAME_EXCL)` to `.templates/<id>`. A
  listed template is always complete; a race with another build of the same
  key fails the rename and leaves the build unfrozen.
- `freeze` and `adopt` refuse unless `Steps` produced the slimming the key
  promises.
- A clone drops `Template.plist`, `Snapshots/` and `vphone.sock`.

## Never booting

The P0 measurement: booting a template after clones exist raised one clone's
private bytes from 0.42 GB to 0.80 GB, and every later clone would inherit
that boot's state. Three layers keep a frozen template from booting:

1. `VPhoneLibrary.bundle(named:)` accepts only a machine name (one component,
   no leading `.`), so no verb taking a machine name reaches `.templates`.
2. `vm launch` checks `VPhoneMachineTemplates.requireBootable`.
3. `VPhoneBootCommand.validate`, which `vphone-vm` runs on its arguments,
   checks it too, DFU included: a folder directly in `.templates`, a frozen
   record, or an unreadable one is refused. A machine in a staging folder may
   boot; the setup boot of a later stage runs there.

## Lifecycle hooks

- **Offline trim** (later): runs inside the CFW install of a build and records
  `Steps.TrimTier` with `VPhoneMachineTemplates.recordSteps(inBundle:)` before
  the freeze.
- **Setup boot** (later): boots the staging machine through vphoned RPCs and
  records `SetupDone`, `ServiceProfile`, `RemovedApps`, `SnapshotDeleted`.
- The key's slimming fields then come from the requested switches; `freeze`
  refuses a build whose steps fell short.
- **Launchpad** builds a machine with its step-by-step pipeline, skips the
  first boot, and runs `vm template adopt <name>`; then
  `vm create <name> --template <id> --skip-first-boot` and its own first boot.

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
volume keys, `mobileactivationd.uuid` and the Data contents the restore wrote.
A template that was never booted shares no trusted host, keychain or Setup
state. `vm create --no-template` builds a machine with secrets of its own.

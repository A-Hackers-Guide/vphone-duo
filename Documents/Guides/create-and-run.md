# Create and run a VM

[Documentation](../README.md) · [Host setup](host-setup.md) · [Compatibility](compatibility.md)

The public firmware workflow applies one complete patch set, including the former EXP changes; patch variants cannot be selected. It patches the boot chain and guest system, installs vphoned, and leaves the user's environment empty. It does not install Sileo, apt, TrollStore, an SSH server or VNC server.

## One-command flow

Supply an iPhone17,3 restore IPSW and a compatible PCC/cloudOS IPSW as local paths or URLs. [Compatibility](compatibility.md) records the pairs actually verified here.

```sh
vphone-cli host preflight
vphone-cli vm create myphone \
  --iphone-source /path/to/iPhone17,3_Restore.ipsw \
  --cloudos-source /path/to/cloudOS.ipsw
```

Creation runs prepare → firmware patch → online DFU restore → host-mounted CFW installation → first GUI boot. It needs network access for the restore ticket. The caller must provide root privileges for CFW installation; this bundle has no authorization dialog or privilege helper. The default virtual disk is 64 GB. `--keep-artifacts` retains the large prepared restore tree; omit it when disk space matters.

By default that pipeline builds a [template](#templates) rather than the VM itself, and the VM is cloned from it. The next `vm create` for the same device, iOS and cloudOS builds, preset and disk size clones from the same template instead of restoring again. Pass `--no-template` to build the VM on its own, as before.

`--cpu`, `--memory`, `--network` and `--unlock-at-startup` set those `vm config` settings on the new VM (defaults: 8 cores, 8192 MB, nat, off). `--skip-first-boot` leaves out the final boot, for a caller that boots the VM itself.

`fw prepare` creates a temporary vphone VM, starts it in DFU, and restores the selected cloudOS IPSW using this project's restore backend. It mounts the restored System volume read-only, extracts the GPU bundle, then removes the temporary VM. This first restore supplies the GPU driver for the second, hybrid iPhone restore. The extracted bundle is cached per cloudOS build in `~/.vphone/gpu-drivers/`, so later machines on the same cloudOS skip the temporary restore. `vm create` and `fw prepare` also accept `--gpu-driver-bundle /path/to/AppleParavirtGPUMetalIOGPUFamily.bundle` to reuse a previously extracted bundle without the temporary restore. The CLI checks its iPhoneOS platform version against the selected cloudOS version. Each restore obtains its own ticket online.

The build also ships an arm64e GPU compiler plugin in the bundle. `fw prepare` copies it into the staged GPU bundle before firmware patching and installation.

Success ends with `First boot: vphoned ping succeeded` and `JB VM created; vphoned connected`. **The verification VM is then stopped.** The ping proves the daemon answered over the host control socket during that boot; it does not leave a running VM behind.

```sh
vphone-cli vm launch myphone  # start the VM window and keep it running
vphone-cli vm stop myphone    # run from another terminal to stop it
```

Closing the VM window, ⌘Q, `vm stop` and Control-C in the `vm launch` terminal all shut the guest down first (vphoned `system.shutdown`) and end the virtual machine once the guest has stopped, or after 15 seconds if it has not. A guest vphoned cannot answer for, such as one in DFU or still starting up, is turned off at once, as pulling the power would. A second Control-C turns it off without waiting.

`vm launch` starts the guest without waiting for vphoned; the daemon connects during boot. The VM window and menu provide Home/power keys, app installation and file browsing. The host control socket is `<VM bundle>/vphone.sock`: one JSON line in, one out. Connections are served concurrently, and the socket also exists with `--no-graphics`, where `tap` and `swipe` go through vphoned's touch injection and screen images come from the guest. Besides `tap`, `swipe`, `key` and `screenshot`, `{"t":"rpc","method":"<vphoned method>","params":{…}}` calls any method in `Research/vphoned_http_api.md`. For example, `input.key` with `{"name":"cmd+v"}` pastes and `input.type` types text. No SSH or VNC endpoint is installed by this workflow.

## Device name

The guest shows the VM's name as its device name, in Xcode's device list and `xcrun devicectl list devices`, and cannot be renamed from inside the guest or from Finder, Xcode or `idevicename`: a rename there reports success and changes nothing. `vphone-vm` hands the name to the guest each time it connects to vphoned, a few seconds into every boot, and the guest keeps it for the next boot. After `vm rename`, Finder and `ideviceinfo` see the new name as soon as the machine is up; Xcode and `devicectl` read it when the device appears and may show the old name until the following boot. An existing machine moved to a bundle with this feature receives the guest library with its environment update and uses it from the boot after that. The guest's own name stays in its preferences, untouched. A VM name of more than 255 UTF-8 bytes, or with a control character, is not used, and the guest shows its own name. See `Research/Guest/device_name_pinning.md`.

## Templates

A template is a complete machine kept in `<library>/.templates/<id>/`. It boots once while it is built, its setup boot, and never again once it is frozen. `vm create` without `--no-template` works out the template key from its options and the two IPSWs before anything is restored: the guest device, the iOS and cloudOS versions and builds, the patch preset and the boot-chain patches it resolves to, the bundle series (`2.8` for 2.8.x), the disk size, and the slimming switches below. Then:

- If a template with that key exists, the VM is cloned from it with a new identity, given the requested CPU, memory and network, and booted once to check vphoned. This takes seconds and needs neither root nor the IPSWs; nothing is downloaded.
- Otherwise the full pipeline runs into a staging folder, `.templates/.building-<id>-<uuid>/`, followed by the setup boot; the result is frozen and renamed to `.templates/<id>/` in one step, and the VM is cloned from it. A second `vm create` with the same key waits for the first instead of restoring a second copy. A failed build stays in its staging folder for inspection.

```sh
vphone-cli vm create phone-a --iphone-source … --cloudos-source …   # builds the template, clones phone-a
vphone-cli vm create phone-b --iphone-source … --cloudos-source …   # clones phone-b, no restore
vphone-cli vm create phone-c --template 3f2a91c0d4e7 --cpu 4 --memory 6144
```

`--template <id>` clones from a template by its identifier (or a unique prefix of four or more digits) and takes no IPSW options. `--device`, `--preset`, `--disk-size` and the slimming switches, when given, must match the template's; a clone cannot change them. CPU, memory, screen and network are not part of the key.

### Setup boot and slimming

The setup boot finishes the template the way every clone should start. It boots the template once and, through vphoned, in this order:

1. deletes the `orig-fs.disabled.rn-*` APFS snapshot `cfw install` left (it holds about 20 MB, and every file trimmed from the System volume until it is gone);
2. skips Setup Assistant (`setup.skip`);
3. waits for first-boot work to settle (`setup.settle`, up to 10 minutes): installd expands the removable system apps on the first boot;
4. removes the system apps (`apps.remove_system`, backups kept in the guest);
5. applies the service profile (`services.profile.apply`), which includes turning off the sign-in follow-up daemons (`followupd`, `appleidsetupd`);
6. reboots, then checks: no snapshot left, Setup done, none of the profile's services running, the removed apps gone, vphoned answering;
7. clears the device name `vphone-vm` pinned for this boot, and shuts the guest down cleanly.

Every step has a deadline. A failed step stops the VM, records nothing and leaves the build unfrozen; `vm create` names the step and how to retry it.

| Switch | Default | Effect |
| --- | --- | --- |
| `--slim on\|off` | on | `off` keeps every app and service. The setup boot still runs: Setup is skipped and the snapshot deleted. |
| `--service-profile trimmed\|none` | trimmed | vphoned's trimmed profile: about 140 launchd jobs off, the App Store daemons and sign-in follow-up among them. |
| `--remove-apps on\|off` | on | Removes App Store, Home, TV, News, FaceTime, iTunes Store, Messages, Games, Find My and Wallet. Camera and Phone stay. |
| `--keep-apps <ids>` | none | Bundle IDs from that list to keep, comma-separated (`com.apple.findmy,com.apple.Passbook`). |
| `--accounts-off` | off | Also turns off `akd`, `amsaccountsd` and `appleaccountd`. The guest then cannot sign in to an Apple Account. |

Each choice is part of the key, so templates with different slimming live side by side and each serves only the creates that ask for it. Removed apps and the profile stay reversible on a clone: `apps.restore_system` puts an app back from its backup, and `services.profile.apply {"profile":"none"}` turns back on exactly what the profile turned off (both through `vphone-launchpad-cli guest rpc`).

What every clone inherits from the template: Setup done, the apps and services as the setup boot left them, the first-boot work installd and the indexers did, and the Data volume as of that boot. It does not inherit a device name: the template's pin is cleared, so a clone shows `iPhone` until its own VM connects and pins the clone's name. A new identity also means the Mac asks "Trust This Computer?" again.

### Finishing a VM as a template

Launchpad builds a machine with its own pipeline and boots it once, leaving it at Setup. To turn such a machine (or any VM straight after creating it) into a template, stop it, give it the setup boot, and adopt it:

```sh
vphone-cli vm stop phone-src
vphone-cli vm template setup phone-src        # headless; --window to watch, slimming switches as for vm create
vphone-cli vm template adopt phone-src        # key from its records and what the setup boot recorded
vphone-cli vm create phone-d --template <id> --skip-first-boot
```

`vm template setup` refuses a running VM and a frozen template. On a VM it reports an app vphoned would not remove and leaves it out of the recorded steps, so the adopted key says what was really done. Given a `.building-…` name from `vm template list` (a `vm create` whose setup boot failed), it sets the build up to its key, which fixes the slimming, and freezes it on success.

### Shared secrets

Every machine cloned from one template shares, with the template and with each other, its SEP root secret, its Data volume keys and the data the restore and the setup boot wrote. One clone could in principle decrypt another's Data volume. A VM that needs keys of its own, for example to sign in to Apple services for multi-device research, should be created with `--no-template` (which takes no slimming switches). Clones get a new ECID, UDID and MAC address on their first start, as with `vm clone --new-identity`, and share every unchanged block with the template on APFS: a new clone costs almost nothing until it starts writing, and a slimmed template leaves it little first-boot work to write.

```sh
vphone-cli vm template list              # id, key summary, STALE with the reasons
vphone-cli vm template show <id> --json
vphone-cli vm template setup myphone     # the setup boot, on a stopped VM
vphone-cli vm template adopt myphone     # freeze a stopped, newly created VM into a template
vphone-cli vm template delete <id>
```

- **Stale.** A template is listed as stale when this `vphone-cli` belongs to another bundle series, when its key has an older format, when its preset now resolves to other boot-chain patches, or when its patch receipt disagrees with its plan. A stale template is never used: `vm create` with its key fails and names it. Delete it to have the next `vm create` build a new one.
- **Adopt.** `vm template adopt <vm>` turns a stopped VM into a template, under the key its own records give (`restore-info.json`, `PatchPlan.plist`, `config.plist`, the disk image, Launchpad's `launchpad.json`, and the steps `vm template setup` recorded in its `Template.plist`). The VM leaves `vm list`. Adopt a VM straight after its setup boot: every clone inherits what its guest has done since. A VM with snapshots is refused, and so is one that would be stale unless `--force` is given.
- **Never booted once frozen.** `vm launch` and `vphone-vm` refuse a frozen template, in DFU too; no machine name reaches into `.templates`, so `vm launch`, `clone`, `export`, `rename` and `delete` cannot pick one up by accident. A template that booted after being frozen would write state into the blocks every later clone inherits, and the clones made before it would stop sharing them.
- **Deleting.** `vm template delete <id>` removes the template; machines cloned from it keep working. The blocks they still share with it are freed only when those machines change them or are deleted, so deleting a template frees less than its size while clones remain. Templates take disk space although `vm list` does not show them; look in `~/.vphone/machines/.templates`, keeping in mind that `du` counts a template and each of its clones in full.

## Manual stages

Use these when investigating or repeating one phase. Keep a DFU boot running while `restore` talks to it:

```sh
vphone-cli vm new myphone
vphone-cli fw prepare myphone \
  --iphone-source /path/to/iPhone17,3_Restore.ipsw \
  --cloudos-source /path/to/cloudOS.ipsw
vphone-cli fw patch myphone

vphone-cli vm launch myphone --dfu &
vphone-cli restore myphone
vphone-cli vm stop myphone

vphone-cli cfw install myphone
vphone-cli vm launch myphone
```

The online restore obtains its ticket in process. For an offline restore, see `vphone-cli restore --help` for `--get-shsh` and `--offline`. The manual flow does not perform the automatic first-boot ping check from `vm create`.

## Library, firmware and backups

| Default path | Contents |
| --- | --- |
| `~/.vphone/machines/<name>/` | One VM, including its disk, `config.plist`, and patch work files |
| `~/.vphone/ipsws/` | Remote source IPSWs, shared by every VM; local IPSWs are read in place |
| `~/.vphone/gpu-drivers/<version>_<build>/` | GPU driver bundles extracted from cloudOS, shared by every VM |

`VPHONE_ROOT` relocates the VM library and both caches. `VPHONE_LIBRARY_ROOT` takes precedence for the library alone, and `--ipsw-cache <dir>` on `vm create` and `fw prepare` for the IPSW cache alone. Downloaded IPSWs stay cached until you delete them (in Launchpad, with File > Downloaded IPSWs…), so a second VM from the same URL downloads nothing; the prepared restore tree is removed after a successful `vm create` unless `--keep-artifacts` is set. VMs prepared by an earlier build may still hold a `.ipsw-cache/` directory; it is safe to delete, and `vm export` leaves it out.

A remote IPSW downloads over four connections at once when its server answers HTTP range requests, as Apple's CDN does; each connection fetches 32 MB segments in turn and resumes a dropped segment where it stopped. `--download-connections <n>` on `fw prepare` sets the count (1 to 16); 1 downloads the IPSW as a single stream, which is also what a server that ignores ranges gets.

```sh
vphone-cli vm list
vphone-cli vm info myphone
vphone-cli vm clone myphone copy
vphone-cli vm clone myphone second --new-identity
vphone-cli vm export myphone --out myphone.tzst
vphone-cli vm import myphone.tzst --name restored
```

`vm clone` copies a stopped machine, using APFS copy-on-write when available; it refuses while the source runs. A plain copy keeps everything, including the device identity (machine identifier and MAC address), so it is a backup and cannot run beside the original.

`--new-identity` makes a second device instead. The copy gets a new machine identifier (ECID), and with it a new UDID, and a new MAC address on its first start. Its fixed IPv4 address, port forwards and a hand-chosen mDNS name are cleared, since they would collide with the original's; an mDNS name `--mdns on` derived from the original's name follows the new name, as on rename. Set new ones with `vm config` if you need them. The guest keeps the original's data, apps and settings, and no restore is needed. Before lockdown tools such as `ideviceinstaller` work, unlock the copy and trust this Mac again. On APFS a copy shares its disk blocks with the original and holds only what it changes, about 0.35 GB after its first boots, although `du` and Finder report the full size for each.

Do not swap `SEPStorage`, `nvram.bin` or the disk image between machines: they were made together by one restore, and a guest whose SEP storage does not match its disk panics at boot.

Run resource-heavy creations **one at a time**. Both the IPSWs and temporary restore tree consume substantial disk space, and patching large caches can be memory intensive. Check free space before starting a second VM. Launchpad places CFW scratch files on the VM library's mounted external volume when applicable; standalone `vphone-cli cfw install` defaults to `/private/var/tmp` and accepts `--work-parent` for a root-owned private directory.

### Sharing disk space between VMs

Two VMs restored separately from the same IPSW share nothing on disk, although much of their disk images is the same: two iOS 27.0 iPhones hold about 8.6 GB of identical bytes at the same places in their roughly 20 GB of data, mostly the system volume. `vm rebase` makes a stopped VM store those blocks once with another VM's:

```sh
vphone-cli vm rebase second --onto template --dry-run
vphone-cli vm rebase second --onto template
```

It rebuilds `second`'s disk image from an APFS clone of `template`'s and writes in only the blocks that differ. Every byte is compared with the original before the image is replaced, so the guest sees exactly the same disk. Only the disk image changes: `SEPStorage`, `nvram.bin`, `config.plist` and the device identity stay as they are. Both VMs must be stopped and on the same APFS volume, and the volume needs free space for the blocks that are written until the old image is released. `--dry-run` reports what would be shared and written without writing anything.

- The space comes back only when nothing else holds the old image's blocks. Snapshots of the VM, and clones made from it, keep them; delete those first or expect no saving.
- `du` and Finder still count each image at its full size. Free space on the volume (`df`) is the honest measure.
- The two images drift apart again as either VM writes to its disk. A base that is never booted, such as a freshly restored VM kept as a template, stays the best base, and rebasing again later recovers what drifted.
- A rebase that is interrupted leaves the VM unchanged and may leave a hidden `.rebase-*` folder in it; delete that folder.

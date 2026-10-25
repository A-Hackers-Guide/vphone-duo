# Data-preserving full OTA payload updates

This is an experimental host-driven installation of Apple's full OTA System
payload. It does not implement Apple's `softwareupdated` download, preparation,
UpdateBrain or update-ramdisk protocol. A successful extraction is not evidence
of a successful OS migration or of any third-party app's compatibility.

The development target is iPad16,1, iPadOS 26.6.2 (23G90) to 27.0.1 (24A446),
with the cloudOS 26.4 (23E5207q) kernel/SEP platform retained. A reference
machine with one re-signed third-party app defines the workload. Installation
experiments use a separate, disconnected canary machine and clones of the
reference machine; the reference machine itself is not modified.

## Why a full OTA

The cloudOS erase ramdisk reformats the container even when told to perform an
update; see [the restore experiments](native_restore_architecture.md#an-in-place-restore-cannot-keep-a-guests-data-2026-10-05).
The existing Apple TV OTA reader already streams `payloadv2/payload.NNN` files
through the system AppleArchive framework. These full payloads provide another
way to replace System while retaining the encrypted Data and User volumes.

A delta OTA needs pristine source files and is unsuitable for a CFW System
volume. `fw ota-stage` therefore checks `AssetData/Info.plist` and refuses
prerequisite builds before staging any payload chunks. Device and build are
checked independently against the OTA's BuildManifest and the prepared IPSW.

The 24A446 iPad16,1/iPad16,2 full OTA is 8,589,934,592 bytes. SHA-256:

```text
9256edce7573577df407155909b63441cd1ed5acbccbb114551cd4003c4ccfd7
```

This exact file was downloaded from the Apple CDN and hashed locally. Its
AppleDB record is `osFiles/iPadOS/24x - 27.x/24A446.json`; use the OTA entry
without `prerequisiteBuild`, including its link's `decryptionKey`. The staged
payload consists of 35 numbered chunks and occupies approximately 5.5 GiB.
`AssetData/payloadv2/links.txt` is a separate, required part of this filesystem:
the numbered chunks omit the duplicate paths it describes.

## Installation boundaries

| State | Treatment |
| --- | --- |
| System volume | Replaced from the full OTA, followed by the target CFW patches |
| Encrypted Data and User volumes | Not mounted or written by the host installer |
| SEPStorage and NVRAM | Retained; included with Disk.img in the pre-update snapshot |
| APFS container and volume identities | Retained; no restore, repartition or ASR operation |
| Kernelcache | Target-patched payload installed in the same private clone as System/TXM, keeping the personalized manifest |
| Preboot TXM | Target-patched IM4P placed in its existing personalized IMG4 during the System transaction |
| Preboot device tree | Existing CFW identity/board repairs run against the retained guest identity |
| OpenAVB and OpenSEP | Selected by `fw ota prepare`; old ROMs/configuration are in the host checkpoint; SEPStorage is retained |
| Host restore-info.json | Target userland version recorded after a completed experimental install |

The kernel, System and TXM update are one stopped-machine transaction. No
intermediate kernel-only disk is published. The stopped snapshot and OTA host
checkpoint are the rollback unit. Restoring Disk.img without its corresponding
SEPStorage and NVRAM is not a valid rollback. Normal VM snapshots still exclude
config.plist and patch selection; OTA saves these separately.

## Running the coordinated update

The source must be running, responsive and finished with migration and Setup.
This implementation pins iPhone/iPad iOS 26 to 27.0.1/24A446 and requires the
source cloudOS version/build to remain unchanged. It refuses deltas, mismatched
device/build inputs and protected apps without matching explicit container
entitlements: a protected app's `com.apple.private.security.container-required`
must name the identifier recorded in its existing data container's metadata. It
does not silently re-sign third-party apps.

Install the built bundle with Launchpad and explicitly bind the stopped test
machine to that version. Start it before running the coordinator. The following
is run from the source checkout; variables name the actual machine, installed
bundle and firmware sources you selected. The full OTA and IPSWs accept local
files or HTTPS URLs. The AEA key is the public firmware key.

```zsh
./scripts/ota-upgrade.zsh "$vm" "$bundle_version" \
  "$target_ipsw" "$source_cloudos_ipsw" "$full_ota" "$public_aea_key" \
  "$protected_app_id"
```

Omit the app ID on a fixture that has no such app installed; repeat app IDs to
protect more apps. A protected app must retain its bundle path, data path,
group-container mapping, version and build, and must reach the foreground.
This does not attest the app's own runtime or network behavior.

| Phase | Required state | Effect |
| --- | --- | --- |
| `capture` | Running source | Save source OS, app paths/entitlements, profile/groups/allow and Auto-Lock outside the machine folder |
| `checkpoint` | Stopped | One fresh APFS disk/SEP/NVRAM snapshot plus APFS clones of host config, patch files, ROMs and old firmware inputs |
| `quiesce` | Running source after checkpoint | Re-enable only profile-owned disabled services; refuse externally disabled migration dependencies |
| `prepare` | Stopped | Verify pinned target/cloudOS, cache sources, preserve old host backups, prepare/patch target, stage full OTA and select OpenAVB/OpenSEP |
| `cfw install` | Stopped, existing helper | Replace System/kernel/TXM on one private disk clone; stage target Apple app programs without mounting encrypted Data |
| `complete` | Running target | Require successful migration for 24A446, update retained Apple programs, dismiss post-update Setup, restore effective Auto-Lock/profile, verify protected app launch |
| `rollback` | Stopped | Restore disk/SEP/NVRAM and saved host configuration/firmware; retain recovery material |

The coordinator performs a final stop/start and repeats `complete` after service
overrides have taken effect. It retries migration/Setup/profile convergence for
up to ten minutes. Failures restore the checkpoint; a checkpoint failure starts
the unchanged source again. A failed rollback leaves the recovery material and
prints the action needed. Every VM/privileged action uses Launchpad.

The durable CLI is also available to coordinators. For example:

```zsh
vphone-launchpad-cli exec --bundle "$bundle_version" fw ota status "$vm"
vphone-launchpad-cli vm stop "$vm"
vphone-launchpad-cli exec --bundle "$bundle_version" fw ota rollback "$vm"
vphone-launchpad-cli vm start "$vm" --headless --wait --timeout 600
```

Explicit `--force` is required to roll back a journal already marked completed,
because that discards writes after its checkpoint. The normal recovery unit is
retained at `<library>/.ota-updates/<machine>/`, with one snapshot referenced by
`Update.plist`. Do not overwrite it to restart a failed preparation. Retry that
phase or roll back first. Disk usage includes the shared firmware cache, staged
OTA, target firmware inputs and changed snapshot blocks; these are not RAM.
The installer still requires more than 50 GiB free when installation begins.

## Retained Apple app programs

The full OTA has placeholders for removable Apple apps. Their old programs
survive on encrypted Data, and a 26.x program may fail to load 27.x frameworks.
The installer decrypts and mounts a verified private copy of the target IPSW's
OS image read-only, and copies its `private/var/staged_system_apps` to the new
System volume. Any extraction failure discards the private disk clone.

`ota.apps.status` compares the staged programs with matching registered Apple
apps in UUID bundle containers. `ota.apps.apply {force:true}` copies each target
program beside the existing one and atomically exchanges them. The old program
and `SerializedPlaceholder.ipa` remain under inactive `.ota-24A446-*` names.
The app is re-registered through the dedicated removable-system-app path.
A repeated apply leaves current, registered apps alone, including any
placeholder written after the old one was quarantined.
Independent user-data/group containers and intentionally removed apps remain
untouched; no `_icli`/`_VPhone` ownership marker is fabricated. This API accepts
no caller-selected source/destination paths or list of third-party app IDs.

## Implementation checks (2026-10-21)

The new OTA journal and ordinary snapshot regression suites passed 21 tests.
The coordinator's simulated success, preparation failure with rollback,
checkpoint failure with source restart, and wrong-binding refusal passed.
The host CLI and guest daemon built with their owning Xcode schemes. These
checks cover implementation behavior; integrated canary acceptance is recorded
separately below when run.

The canary run reached 27.0.1 (24A446), completed DataMigrator with
`DMLastMigrationResults.success=true`, and installed 24,835 hard links. It was
rolled back before the network commit because the source Auto-Lock policy was
120 seconds while the target effective policy remained 300 seconds after the
Settings write and cold-boot retries. The target was not committed.

System/TXM installation requires a private APFS clone. Unlike the legacy full
installer's cross-volume fallback, this operation never edits Disk.img in
place. Compatibility patch failures abort before the clone is published. The
existing personalized TXM manifest and restore information remain byte-identical.
The target `trxm` type must match both containers.

The old Guest receipt cannot be reused for the new System contents. Its prior
patch set is reset before applying target patches, including patches common to
26 and 27. Otherwise a cache patch could be incorrectly skipped because it was
already recorded for the erased 26 cache.

All payload chunks are copied into the root installer's private work folder and
validated together before extraction. Validation rejects absolute paths,
traversal, incompatible object types, type changes and a member below a symlink
or another non-directory, including across chunk boundaries. Absolute guest
symlinks themselves are retained. Apple's empty-path root directory entry is
accepted. The root installer repeats the validation after copying the files;
an earlier unprivileged check is not trusted as proof of the later bytes.
The hard-link list is copied and checked with the same chunks before extraction.
Every `=` source must be an archived regular file; every `+` destination must
be new and must not traverse any non-directory. After extraction, `linkat`
operates through confined parent descriptors and the new leaf's inode is checked
against the opened source. A missing list aborts a full update.

## Experimental procedure

The normal commands are dispatched through `vphone-launchpad-cli exec` with the
experimental bundle explicitly selected. The default bundle and other machines
do not change. Prepare the target IPSW and cloudOS sources with `fw prepare`
on a stopped experimental machine, after taking a snapshot. Do not run
`restore`.

The added verb is:

```text
fw ota-stage <vm> --source <local-full-ota> --key <base64-key> --build <target-build>
```

It stages into `OTAUserland/` and writes `Upgrade.plist` only after the archive
passes the full-update, device, build and chunk checks. `--verify-staged` reads
the already staged payload and verifies its filesystem paths without installing
it. Staging refuses to replace an existing OTAUserland folder.

Then run `fw patch` for the target, `cfw update-kernel`, and enable only
`system-exp-ota_userland` on top of the desired preset with `fw set-patches`.
`cfw install --keep-artifacts` performs the experimental System/TXM transaction.
The new patch is off in Standard and both TV presets. A matching staged OTA and
a stopped disk/SEP/NVRAM snapshot are required even if a broader preset selects
the patch. Keeping artifacts allows diagnosis and another offline attempt.

After installation, first prove the target OS boots and can read a marker from
the encrypted Data volume. Then verify cold boots and guest reboots before
testing the real application state. A version shown in Launchpad comes from
host metadata and is not a substitute for `device.info` from the booted guest.

## Evidence and validation

| Evidence | Observation | Consequence |
| --- | --- | --- |
| E-001: `vm list`, `device.info` on the reference machine | iPad16,1, 26.6.2/23G90, cloudOS 26.4, 8 CPUs and 8192 MB, jailbroken | Defines the original system and workload |
| E-002: `apps.info`, `processes.list` | Protected app footprint 228,214,416 B, resident 555,630,592 B | A single running-process sample, not a cold-launch or media peak |
| E-003: CDN metadata and local SHA-256 | Full 24A446 OTA matches the digest above | Pins the exact target asset |
| E-004: OTAArchiveTests | 16 tests passed, including prerequisite rejection and cross-chunk symlink traversal | Offline parser/path validation; no guest compatibility claim |
| E-005: FirmwarePatchSetCatalogTests and CustomFirmwareKernelcacheSwapTests | 27 tests passed; TXM container fixture preserves IM4M and refuses a kernel payload | Offline selection/container validation |
| E-006: `fw ota-stage --verify-staged` on the canary | 35 real payload chunks passed path validation | The real OTA has a supported full filesystem payload |
| E-007: canary | Booted at 26.6.2, wrote a 54-byte Data marker, stopped and saved `pre-ota-26` | Establishes the encrypted-data rollback and migration test |
| E-008: first OTA boot | Guest reported 27.0.1 (24A446), vphoned answered, and the 54-byte Data marker read back exactly; the window stayed at the Apple logo/0 fps | System, SEPStorage and Data unlock worked; UI acceptance failed |
| E-009: `logs.crashes` + `logs.crash` | `com.apple.datamigrator` reported `com.apple.VoiceShortcuts.ShortcutsMigrator (Shortcuts.migrator) - Returned NO from -performMigration: (upgrade) (prev build 23G90)`; `DMLastMigrationResults.success` was false | The first UI regression is a DataMigrator plugin failure during the 23G90 to 24A446 upgrade, not an SEP or Data-volume loss |
| E-010: second OTA boot after forced Cryptex sync | SpringBoard PID 330 was alive and the screen still showed Apple logo/0 fps; marking migration success and respringing did not restore UI | Cryptex replacement was necessary but not sufficient; a real migration fix or skip path remains required |
| E-011: post-service-restore migration stackshot | PreferencesMigrator waited on locationd, which waited through liveactivitiesd on launchd-throttled audiomxd | The dependency chain identifies a media initialization failure below the migration plugin |
| E-012: temporary SIGTRAP tracer on the disconnected canary | audiomxd called CFRetain(NULL) from MediaExperience; CelestialCFCreatePropertyListForModelAndBundleIdentifier returned NULL for J410/CategoriesThatShareVolumes.plist and a valid object for Default | The failure is a missing per-device resource, not low-memory pressure; the reference machine was not instrumented |
| E-013: exact full OTA, rehashed to the digest above | links.txt has 24,835 destinations; J410's missing category/route/volume resources are among them, with archived source files | The first implementation omitted the separate hard-link phase; payload extraction alone is incomplete |
| E-014: corrected ArchiveKit tests and real OTA validation | 94/94 archive tests passed; all 35 actual chunks and 24,835 links passed combined path/source validation | Offline validation of the fix |
| E-015: corrected canary and reference-clone reruns | Real migration returned success=true at 24A446; encrypted Data marker retained; one subsequent setup.skip persisted across cold/guest reboots | The missing-link migration failure is repaired; no synthetic success preference is used as acceptance |
| E-016: runtime comparison on a 27 reference clone | 26's runtime HOME used its legacy signed-identifier container, while 27 used the bundle-ID container; both loaded the app's injected library | A loaded library or visible UI does not show the app reached its existing data; stale state from the source must not be accepted |
| E-017: explicit legacy container entitlement and re-registration | The app reopened its existing data container and wrote fresh state from the current process; UUID and original entitlement values retained | The application needs an explicit container compatibility step; Data was not copied to a different container |
| E-018: reference clone at 4096/3072/2048 MB, service profile none | Existing data reopened from the current process, pressure level 1; 2 GB also passed guest reboot and app reopen | Offline startup is possible at 2 GB; no network or heavy-media claim |
| E-019: retained Apple app bundles on Data | 26.6 Calendar/Music widgets failed with DYLD Symbol missing against 27 frameworks | System-only payload extraction also needs an explicit preinstalled-app compatibility phase |
| E-020: target IPSW staged_system_apps | Replaced 38 already-installed Apple app bundles at their original paths, retaining old copies and all independent data paths; cold boot and Calendar/Music foreground passed, no new crash reports in the bounded follow-up | Validates a clone-only app synchronization experiment; not yet automatic in the installer |
| E-021: final 2 GB complete-app-set sample | The protected app's data check passed; pressure briefly reached level 2 then returned to level 1 with the same app PID and no new jetsam report | 2 GB is an experimental floor, not a demonstrated memory margin |

The temporary trace was removed from the launchd job and the original audiomxd
plist was reloaded after collecting E-012. Diagnostic wrappers and logs were
under `/private/var/tmp`; no shared-cache code was patched. Setup Assistant was
observed changing SetupDone back to false; setup.skip made it true again, but
that does not repair or certify migration. The real rerun starts from the
stopped pre-migration disk/SEP/NVRAM snapshot, before any target migration or
diagnostic preference changes.

The earlier failed boots remain diagnostic history. The corrected rerun actually
completed migration before setup.skip, and retained Setup completion on later
boots. Marking a failed migration successful by hand is not an accepted path.

Path P-001: snapshot the stopped 26 guest (E-007), prepare the target firmware
and full OTA (E-003/E-006), update the kernel and atomically replace System/TXM,
then read `device.info`, real migration results and the Data marker from the
booted 27 guest. After the missing hard links were restored, this passed on the
canary and the reference clone. Retained third-party signing-container policies
and preinstalled Apple app programs require the explicit compatibility steps
below before the app is assessed.

## Retained applications after a major userland change (2026-10-21)

### Preserve removed system apps (2026-10-25)

The production `wecom-01` and `wecom-02` guests retained all nine original
`apps.remove_system` backups after the 24A446 OTA, but SpringBoard's IconState
again contained eight of their identifiers. `apps.list` omitted them and
`staged_system_apps` was empty. A native LaunchServices probe found
`isPlaceholder=true`, `isInstalled=false` records at new UUID bundle paths,
including News, which was not in the visible icon lists. The SMS placeholder
Info.plist named `Executable` and `MinimumOSVersion=27.0`. The normal system
uninstall API refused it. Installed-app absence was therefore a false
acceptance signal, not proof that the removal policy survived migration.

`apps.removed_system` now includes fresh LaunchServices `registered`,
`installed`, `placeholder` and current `bundle_path` fields alongside each
original backup. Capture stores the valid absent/placeholder IDs in
`removed_system_apps`; an already reinstalled program is excluded even when
an old backup remains. `ota.apps.apply` accepts that baseline as
`removed_bundle_ids`, removes those registrations (including placeholders)
and their validated UUID program containers without overwriting the old
backups or touching independent user/group containers, then updates retained
programs. It returns `removed_pending`; complete, commit and verify all check
that the removal baseline is absent and its backups remain usable. There is
no blanket icon-layout reset or SpringBoard restart.

Legacy journals infer only absent apps and placeholders with valid removal
backups. They never infer removal of a currently installed program from a
historical backup alone. An older daemon that cannot report placeholder
state fails verification instead of silently accepting the OTA. The source
backup manifests, rather than a hardcoded default trim list, determine policy.

This is an application-state reconciliation change, not a new binary patch
or patch preset. Migration may seed placeholders before complete reconciles
them; the no-placeholder gate is required before networking is committed.

Production repair used the same native enumeration/unregistration bridge in a
temporary signed helper, restricted to the nine IDs whose original manifests
were present. Every target had to be a placeholder, not an installed program;
the UUID container and its Info.plist identifier were checked before mutation.
The new placeholder containers were renamed into
`/private/var/db/vphoned/ota-placeholders-20261025/` after LS absence read-back,
keeping recovery material instead of destroying it. Both machines returned
nine absent registrations, zero failures, and no matching identifiers in
SpringBoard's persisted icon lists. Neither SpringBoard nor WeCom was restarted:
WeCom PIDs remained 69286/5397, and bundle/data/group paths and version/build
matched the before samples. The original nine removal backups remain separate.
Both machines passed a second invocation with zero changes and zero registered
targets; all nine original backups remained restorable with their original
removal dates. The temporary launchd jobs were then unloaded.

Validation: complete Debug `VPhone` bundle build/admission passed; all ten
`OTAUpdateTests` passed, including absent/placeholder/reinstalled distinctions,
old-daemon rejection, corrupt-backup rejection and rollback/commit coverage.
The maintenance script passed all 148 Swift policy checks and 13 APFS C parser
checks with AddressSanitizer/UndefinedBehaviorSanitizer. The shared native
header now explicitly marks legacy pointers `_Null_unspecified`, preserving
their Swift import while satisfying nullability completeness under `-Werror`;
no warning was disabled. No full OTA or cold reboot was performed
on these business machines for this repair. The new bundle was built locally;
the production repair did not publish or replace their bundle.

The protected app's executable had an ad hoc CodeDirectory identifier different
from its bundle ID, with no explicit container-required entitlement. The
existing data container's metadata matched that signing identifier. A same-byte
runtime probe used the existing container on 26 but the ordinary bundle-ID
container on 27. Its injected library was loaded in both cases; on 27 it
therefore missed the state it keeps in the existing container. Re-signing a copy
with the exact existing container identifier in
`com.apple.private.security.container-required`, preserving all other
entitlements and the executable UUID, followed by app re-registration, let the
current process reopen the existing data. `fw ota capture` checks this value
against the container's `MCMMetadataIdentifier`. This was done only on the
disconnected clone, with the original binary and snapshot kept. It is not a
generic automatic re-sign policy.

Apple apps stored on Data also retained 26 binaries. Calendar and Music widget
crashes reported missing CalendarLink/MusicKitInternal symbols, rather than
jetsam. The OTA supplied AppPlaceholders but not the complete staged removable
app programs. The matching IPSW's root image contained complete 27 bundles in
`private/var/staged_system_apps`. A clone-only experiment selected the 38 apps
already installed, staged each in its existing bundle container, retained the
old bundle, then replaced the program directory. It neither removed nor
changed the independent user-data container paths. Cold boot and foreground
Calendar/Music passed; bounded post-boot crash reports had no new entries.
The old SerializedPlaceholder.ipa repair path and every individual system-app
feature remain untested. These application steps are not yet part of automatic
`cfw install`; a successful System/TXM transaction alone is insufficient.

Diagnostic launchd stdout persists and appends across boots. Always parse the
last JSON document and require a new heartbeat; when clearing task-owned stdout,
unload the job first so launchd does not retain an unlinked output descriptor.
Allow a slow low-memory diagnostic client to finish instead of cancelling and
restarting it every three seconds. Launchpad also restores bundle environment
libraries on host cold start, so temporary diagnostic library bytes must be
read back before interpreting a probe.

## Memory acceptance

Use the same CPU count, screen geometry, app binary and workload at each memory
size. Keep 8 GB as the migration baseline, then test 4096, 3072 and 2048 MB with
stopped-machine configuration changes. A 7 GiB shared-region address range is
virtual address space; it is not a requirement for 7 GiB of physical RAM.

OpenAVB and OpenSEP already contain the low-memory unbacked-register fixes
documented in [OpenAVB](../Firmware/openavb_boot_rom.md) and
[OpenSEP](../Firmware/opensep_sep_rom.md). Their existing 6144 MB results do not
prove 2–4 GB iPad support.

For every size, record cold-boot time, guest reboots, pressure level, jetsam
events, process restarts, the protected app's footprint and resident memory, and
the slowest operation. Hold the app at one version and verify its image UUID
before comparing sizes. A booted UI or a loaded library does not prove the
app's own network behavior; that needs separate evidence, and no real traffic
should be generated merely to obtain a benchmark.

The claim that 27.0.1's animations use fewer resources remains a performance
hypothesis until paired measurements establish a benefit for this app.
Boot/install memory and foreground media/recovery peaks can set the minimum
even when steady-state process footprints are small.

# tvOS support

Validated on 2026-10-15: AppleTV5,3 tvOS 26.4 beta 1 (23L5208m) on the
cloudOS 26.4 beta (23E5207q) vphone600ap platform boots to TVSetup and Settings.
The same VM booted normally with four CPUs after installing the persistent
kernel fix, without a debugger. Arrow keys, Return and Escape navigation were
confirmed by the user. Device > Back sends the same native Escape key pair;
that menu action has not been separately confirmed.

Validation covers the specific donor/kernel pairing listed below. Settings >
About reports tvOS 26.4 (23L5208m), an IPv4 address, and 1080p HD / 120 Hz.
The display mode is reported metadata, not measured rendering performance.
Activation reports Failed and the model is Not Applicable. Apple services,
audio, video playback, third-party apps and long-term stability remain untested.
No tvOS pairing is advertised in the firmware catalog.

## Firmware and storage

- Donor: Apple TV HD, `AppleTV5,3`, board `j42dap`, plain arm64 / TVOS.
- Kernel, boot chain and SEP: cloudOS 26.4 beta, `vphone600ap`.
- [Apple-hosted donor IPSW](https://updates.cdn-apple.com/2026WinterSeed/fullrestores/089-95491/1679DEB6-820D-40A8-9F28-1735EFDFB01D/AppleTV5,3_26.4_23L5208m_Restore.ipsw).
- Verified SHA-256: `2128c348ffbb0f65096ac3e7be22e901e09773e02c17edbce4c0647769c24ae8`;
  length 5,269,316,627 bytes.
- The lab reuses one logical 32 GB disk, about 11 GiB allocated. No second
  VM, template, or automatic PCC GPU recovery disk was created.

The matching release numbers motivated the pairing investigation; they do not establish
compatibility with other builds. The beta archive, FirmwareOriginals and
restore tree are retained locally for reproducibility and rollback.

## Reproducing the validated configuration

Use the built bundle's `vphone-cli` on a host configured according to
[host setup](../../Documents/Guides/host-setup.md). Both IPSWs must be supplied
locally: the donor above and cloudOS 23E5207q. Other pairings are unvalidated.
The VM and the installer's temporary directory must share an APFS volume;
TV guest updates refuse an in-place fallback when cloning is unavailable.
Copy-on-write updates share unchanged blocks, but require space for changed data.

For a **new** VM only, run these commands in zsh, replacing the three paths.
Do not run `vm new` or restore against an existing VM you want to preserve.
This manual pipeline creates one 32 GB disk and no template. The historical
`--iphone-source` option accepts the TV donor.

```zsh
cli='/absolute/path/to/VPhone.bundle/Contents/MacOS/vphone-cli'
tv_ipsw='/absolute/path/to/AppleTV5,3_26.4_23L5208m_Restore.ipsw'
cloud_ipsw='/absolute/path/to/cloudOS_23E5207q_Restore.ipsw'
export VPHONE_LIBRARY_ROOT="$HOME/vphone-tvos"
vm='tvos-26_4-beta'
"$cli" vm new "$vm" --cpu 4 --memory 4096 --disk-size 32
"$cli" fw set-patches "$vm" --preset standard \
  --allow kernel-exp-tv_tpro_pagers \
  --allow system-dyld-exp-tv_tpro \
  --block dyld-boot-iomfb_force_kern \
  --block dyld-boot-iomfb_swapend \
  --block dyld-boot-lockdown_mode \
  --block dyld-boot-lsd_embedded_reg \
  --block dyld-boot-maxslide \
  --block dyld-boot-xpc_lwcr \
  --block dyld-cfw-camera \
  --block preboot-cfw-devicetree_board_audio \
  --block preboot-cfw-devicetree_haptics \
  --block preboot-cfw-devicetree_iphone_product \
  --block preboot-cfw-devicetree_microphone_array \
  --block system-apps-cfw-attitude \
  --block system-backboardd-cfw-gyroscope \
  --block system-campo-cfw-entitlements \
  --block system-debugserver-cfw-install \
  --block system-diskimagesiod-cfw-is_mount_complete \
  --block system-extensions-boot-gpu_bundle \
  --block system-installcoordination_proxy-cfw-persona_lookup \
  --block system-jetsamproperties-cfw-disable_allowed \
  --block system-launchd-boot-jetsam_panic_guard_bypass \
  --block system-launchd_cache_loader-boot-unsecure_cache_gate \
  --block system-launchdaemons-boot-environment \
  --block system-locationd-cfw-disable_auto_cohort \
  --block system-mobileactivationd-boot-should_hactivate \
  --block system-paravirt_gpu-cfw-heap_index_offset \
  --block system-systemversion-cfw-build_version \
  --block system-virtiosound-cfw-hal_plugin \
  --block system-virtualaudio-cfw-microphone_graph_chains \
  --block system-virtualaudio-cfw-mute_set_throw \
  --block system-virtualaudio-cfw-speaker_graph_chains \
  --block system-virtualaudio-cfw-speaker_protection_gate \
  --block system-virtualaudio-cfw-speaker_raw_chains \
  --block system-virtualaudio-cfw-speaker_route_throws \
  --block system-virtualaudio-cfw-volume_mode_precondition \
  --block system-vphoned-boot-install
"$cli" fw prepare "$vm" --device AppleTV5,3 \
  --iphone-source "$tv_ipsw" --cloudos-source "$cloud_ipsw"
"$cli" fw patch "$vm"
"$cli" vm launch "$vm" --dfu
```

Leave DFU running. In a second terminal, set the same `cli`, `vm` and
`VPHONE_LIBRARY_ROOT` variables, then run:

```zsh
"$cli" restore "$vm"
"$cli" vm stop "$vm"
sudo "$cli" cfw install --library-root "$VPHONE_LIBRARY_ROOT" "$vm" --keep-artifacts
"$cli" vm launch "$vm"
```

If host preflight refuses the VM binary, run its printed allowlist command and
retry the launch. Navigate setup with arrows and Return; Escape goes back.
No vphoned first-boot probe is appropriate for this configuration.

`fw set-patches` replaces all overrides, so always retain the entire selection
above. On an installed, stopped VM, guest-side changes use `sudo "$cli" cfw
update-environment --library-root "$VPHONE_LIBRARY_ROOT" "$vm"`; kernel changes
use `sudo "$cli" cfw update-kernel --library-root "$VPHONE_LIBRARY_ROOT" "$vm"`.
Neither requires another restore. A prior research installation must first
remove its diagnostic jobs with the preserved research bundle; the PR bundle
does not contain those removed patch implementations.

## Required implementation

1. Admit AppleTV5,3 explicitly. Copy its TV idiom, identity, 1x artwork and
   `app-macho-architecture=arm64` from the donor device tree. The virtual display
   uses 1920x1080; 72 ppi is a provisional VM value, not television metadata.
   Preserve the virtual identity in the restore tree. Non-iPhone restore-tree
   names retain the existing `iPhoneOS_…_Restore` compatibility prefix.
2. Admit the monolithic TV filesystem only after validating its erase identity,
   TVOS platform and required component paths. It contains neither OS nor App
   cryptex; its cache remains at `System/Library/Caches/com.apple.dyld` and uses
   architecture `arm64`. Other guest families keep their cryptex layout.
3. Rehash the unchanged TV `OS`, `SystemVolume`, `StaticTrustCache` and
   `Ap,SystemVolumeCanonicalMetadata` with SHA-384 in the hybrid manifest.
   J42d's SHA-1 donor digests failed PCC metadata authentication and sealing;
   the corrected hybrid restore completed.
4. Apply the existing seputil/gigalocker repair. Block unvalidated iOS guest
   payloads, graphics/audio hooks and shared-cache patches. Preparation now
   respects the GPU patch selection, avoiding an unnecessary recovery VM.
5. Explicitly enable `system-dyld-exp-tv_tpro` and
   `kernel-exp-tv_tpro_pagers`. Both are off in Standard. Keep the donor's
   native shared cache and page-in linking intact.
6. Forward Escape to the TV's native virtual keyboard instead of consuming
   it as an iPhone edge swipe. Device > Back uses the same keyboard path,
   without vphoned. Backspace remains available for editing text.

The dyld operation rewrites only the exact `dyld_hw_tpro` and
`dyld_hw_tpro_pagers` parameter-name prefixes to `vphn`, in both standalone
and cached dyld. It validates TVOS/arm64, symbol bounds, getenv references and
presence checks, then re-attests the modified code-signature slots. A backup
and shared-cache undo record support paired rollback. An existing patch must
have both records before another write. Paired failures abort the install and
discard its private disk clone; rollback retires undo only after both images
are restored.

## Kernel cause and persistent fix

The embedded research kernel UUID was
`784F88D3-2AF5-3D4A-AB00-365607646E44`. Native runtime tracing caught
MobileGestaltHelper, UUID `7CF0ED37-E30C-38AA-AE6C-F10A7CA15BC8`, at a libobjc
store with ESR `0x9200004f` and unslid FAR `0x1ea57c808`. Its DATA_CONST
RW|COPY request (`0x13`, size `0xa23c000`) returned KERN_PROTECTION_FAILURE.
Following the remap/extract calls showed a TPRO-tagged map entry while dyld
used an ordinary writable request. The source entry allowed maximum RW.
The local symbol dataset was unavailable; function descriptions were derived
from native control flow and correlated with XNU, not claimed symbol lookups.

The native `sprr_tpro_pagers` tunable controls tagging these ranges. Setting
its live value from 1 to 0 made subsequent COPY requests succeed and allowed
TVSetup to appear. No other functional debugger write was made.

The persistent patch changes only the integer tunable's initial four bytes.
It locates the unique NUL-terminated name, validates the four-byte integer
startup descriptor and its data pointer, and requires one TUNABLES registration
with an executable initializer. It accepts only defaults 0 or 1. Both segment
bounds and actual file bounds are checked. The fileset's outer `__DATA` contains
the embedded `__KLDDATA`. No observed offsets or instruction words are baked
into the patch; unsupported or ambiguous layouts fail the selected operation.
Its applicability is limited to the 26.4 donor/kernel pairing.

`cfw update-kernel` rebuilt from FirmwareOriginals and replaced only the
installed Preboot kernel payload, retaining the manifest and volumes. A normal
four-CPU boot subsequently reached the Language screen, and the user navigated
to Settings > About. Disabling the kernel patch and running the same command
rebuilds from pristine bytes; the dyld operation is separately reversible.

## Validation and PR scope

The trimmed PR passed:

- 89 tests in seven firmware suites, including the real research kernel's
  exact four-byte change, blocked-gate byte identity and malformed/truncated
  tunable descriptor rejection.
- 36 final follow-up tests in four suites covering TV guest patch admission,
  TV dyld, patch declarations,
  missing-backup rejection and injected rollback failures. These overlap
  the preceding firmware suites and are not an additional unique-test count.
- 17 core identity/catalog tests, 15 archive admission tests, and the
  Launchpad IPSW classification tests.
- The final complete VPhone bundle build and bundle admission checks.
- A normal four-CPU, 4 GiB boot after removing the diagnostic patches. The
  user confirmed the UI works and Escape goes back. Device > Back uses the
  same key path but has not been separately confirmed.

The PR excludes diagnostic executables, launchd logging/cache modifications,
the abandoned page-in-linking fallback and the unused conclave change.
The lab's guest receipt after cleanup contains only TV dyld TPRO and the two
seputil/gigalocker repairs. TV environment updates recognize the guest receipt
when vphoned is omitted. Unreadable cache undo logs abort instead of being
silently replaced.

The titlebar Home button requires vphoned and remains disabled in this
configuration. Native arrow, Return and Escape input does not require it.
Activation, model metadata, audio and Apple services retain the limitations
listed above; this validation does not establish full Apple TV compatibility.

Research helpers and the prior bundle are retained locally under
`.build/tvos-research/pr-backup`, outside the PR. Boot evidence is in
`.build/tvos-research/pr-clean-boot.log`; the Settings screenshot and earlier
native runtime transcripts remain beside it. No second VM disk was created.

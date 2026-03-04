# JB Mount Failure Investigation (2026-03-04)

## Symptom

- `make setup_machine JB=1` reached `cfw_install_jb` and failed at:
  - `Failed to mount /dev/disk1s1 at /mnt1 (opts=rw).`

## Runtime Evidence (Normal Boot)

From `make boot` serial log:

- APFS mount tasks fail with permission errors:
  - `mount_apfs: volume could not be mounted: Operation not permitted`
  - `mount: /private/xarts failed with 77`
  - `mount: /private/preboot failed with 77`
  - launchd panics: `boot task failure: mount-phase-1 - exited due to exit(77)`
- Ignition/boot path shows entitlement-like failure:
  - `handle_get_dev_by_role:13101: disk1s1 This operation needs entitlement`

This is consistent with missing mount-policy bypasses in the running kernel.

## Kernel Artifact Checks

### 1) Ramdisk kernel identity

- `vm/Ramdisk/krnl.img4` payload hash was byte-identical to:
  - `vm/iPhone17,3_26.1_23B85_Restore/kernelcache.research.vphone600`

So ramdisk boot was using the same restore kernel payload (no accidental file mismatch in `ramdisk_build`).

### 2) Patchability state (current VM kernel)

On `vm/iPhone17,3_26.1_23B85_Restore/kernelcache.research.vphone600`:

- Base APFS patches:
  - `patch_apfs_vfsop_mount_cmp` -> not patchable (already applied)
  - `patch_apfs_mount_upgrade_checks` -> not patchable (already applied)
- Key JB patches:
  - `patch_mac_mount` -> patchable
  - `patch_dounmount` -> patchable
  - `patch_kcall10` -> patchable

Interpretation: kernel is base-patched, but critical JB mount/syscall extensions are still missing.

### 3) Reference hash comparison

- CloudOS source `kernelcache.research.vphone600` payload:
  - `b6846048f3a60eab5f360fcc0f3dcb5198aa0476c86fb06eb42f6267cdbfcae0`
- VM restore kernel payload:
  - `b0523ff40c8a08626549a33d89520cca616672121e762450c654f963f65536a0`

So restore kernel is modified vs source, but not fully JB-complete.

## Root Cause (Current Working Hypothesis)

- The kernel used for install/boot is not fully JB-patched.
- Missing JB mount-related patches (`___mac_mount`, `_dounmount`) explain:
  - remount failure in ramdisk CFW stage
  - mount-phase-1 failures and panic during normal boot.

## Mitigation Implemented

To reduce install fragility while preserving a JB target kernel:

- `scripts/fw_patch_jb.py`
  - saves a pre-JB base/dev snapshot:
    - `kernelcache.research.vphone600.ramdisk`
- `scripts/ramdisk_build.py`
  - builds:
    - `Ramdisk/krnl.ramdisk.img4` from the snapshot
    - `Ramdisk/krnl.img4` from post-JB kernel
- `scripts/ramdisk_send.sh`
  - prefers `krnl.ramdisk.img4` when present.

## Next Validation

1. Re-run firmware patch and ramdisk build on the current tree:
   - `make fw_patch_jb`
   - `make ramdisk_build`
   - `make ramdisk_send`
   - `make cfw_install_jb`
2. Verify remount succeeds in JB stage:
   - `/dev/disk1s1 -> /mnt1`
3. Re-test normal boot and confirm no `mount-phase-1 exit(77)` panic.

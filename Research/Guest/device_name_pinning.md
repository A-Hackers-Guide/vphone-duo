# Device name pinning

The host can give a guest a fixed device name, the one Xcode's DeviceHub,
`devicectl`, Finder and the guest's own Settings show, and keep it from being
renamed inside the guest. This note covers the guest half:
`libdevicename.dylib`. The host half writes the NVRAM variable it reads.

Static analysis of the iOS 27.0 (24A435) `configd` and `lockdownd` from an
`iPhone17,3` guest, 2026-10-07. Addresses are from those binaries. Status: not
yet run on a guest; see [Verification](#verification).

## Where the name lives

The device name is `System/System/ComputerName` in
`/private/var/preferences/SystemConfiguration/preferences.plist`. Nothing reads
it from there directly. configd publishes it into the dynamic store, and every
reader goes through the store:

```text
preferences.plist ── configd PreferencesMonitor ──> Setup:/System { ComputerName, ComputerNameEncoding }
                                                        │
       SCDynamicStoreCopyComputerName ─────────────────┤
         lockdownd copy_device_name  (lockdown GetValue DeviceName: Finder, Xcode, devicectl)
         MobileGestalt UserAssignedDeviceName, UIDevice.name
```

configd's `updateConfiguration` (PreferencesMonitor, statically linked into
`/usr/libexec/configd`; `0x100062098`…) does the publishing:

1. `SCDynamicStoreCopyMultiple(store, NULL, ["^Setup:.*"])`: what the store has.
2. `SCPreferencesCopyKeyList`, then `SCPreferencesGetValue(prefs,
   kSCPrefSystem)` flattened from `/` into `Setup:/…` keys (`0x100064578`), so
   `System/System` becomes `Setup:/System`. The current set is flattened the
   same way.
3. Keys whose value did not change are dropped; keys that disappeared are
   collected for removal.
4. One `SCDynamicStoreSetMultiple(store, keysToSet, keysToRemove, NULL)`
   (`0x100062c04`).

Renames come in through lockdownd's `set_device_name` (`0x1000073b0`):
`SCPreferencesCreate("com.apple.mobile.lockdown")`, `SCPreferencesLock`,
`SCPreferencesSetComputerName(prefs, name, kCFStringEncodingUTF8)`,
`SCPreferencesSetHostName` and `SCPreferencesSetLocalHostName` with a sanitized
name, `SCPreferencesCommitChanges`, `SCPreferencesApplyChanges`. These are
lockdownd's only callers of the three setters. A failing setter is only
logged, and the function still commits. It has two callers:

- startup (`0x100011ec0`): when `copy_device_name` finds no name, lockdownd
  names the device after `MarketingDeviceFamilyName`;
- the lockdown `SetValue DeviceName` handler (`0x10001ed7c`), which ignores
  the result. The host's rename (Finder, `idevicename`) arrives here.

## The channel

Before every boot, `vphone-vm` writes the VM's name (the folder holding
`config.plist`) to NVRAM variable `vphone-device-name`: its UTF-8 bytes, no
terminator. There is no setting; the device name is the VM name, so `vm
rename` applies from the next boot. A VM name that cannot be a device name
(the rule below, `VPhoneGuestDeviceName` on the host) is not written, and
`vphone-vm` removes the variable instead. The guest reads it once per process as the
`IODeviceTree:/options` property of that name, then under Apple's NVRAM GUID
(`7C436110-…:vphone-device-name`) if the bare name is absent.

The value must be 1 to 255 bytes of valid UTF-8 with no control characters;
trailing NULs are dropped, and a CFString is accepted as well as CFData. Any
other value means the feature is off and the library passes every call
through.

## configd: publishing the pinned name

`SCDynamicStoreSetMultiple` is interposed. For a call that sets or removes
anything under `Setup:`, which in configd is the preferences monitor,
`Setup:/System` is rewritten so its `ComputerName` is the pinned name and its
`ComputerNameEncoding` is UTF-8. Other entries stay.

- The call sets `Setup:/System`: its value is pinned.
- The call leaves it out because it did not change: the store's current value
  (`SCDynamicStoreCopyValue`) is pinned and added if it names anything else.
  This covers a first boot whose preferences have no name: the store gets one
  anyway, so lockdownd's startup naming finds a name and does not run.
- The call removes it: the removal is dropped and a value holding the pinned
  name is set instead.

`SCDynamicStoreSetValue("Setup:/System", …)` is pinned the same way. No configd
caller is known to set that key directly.

The pin is applied when configd publishes, not when it reads the
preferences. Replacing what `SCPreferencesGetValue(prefs, kSCPrefSystem)`
returns would reach the same flattening, but the monitor's model-change path
(`sub_10006155c`) reads that value and writes it back with
`SCPreferencesSetValue` around `__SCNetworkConfigurationSaveModel`, which
would commit the pinned name to disk. Applied at publication, it never
reaches `preferences.plist`: the file keeps the guest's own name, and a guest booted without the
variable shows that name again.

Not pinned: `LocalHostName` and the DNS host name, which are separate keys
derived from the name when it is set; set-hostname's
`__SCPreferencesCopyComputerName` (`0x100049fcc`), which reads the file
directly to decide a DNS host name after a reverse lookup.

## lockdownd: refusing renames

While a name is pinned, `SCPreferencesSetComputerName` with any other name
returns false and sets `kSCStatusAccessError` (`_SCErrorSet`, exported by
SystemConfiguration). The host name and local host name setters that follow on
the same preferences object are refused too, so the commit changes nothing.
A rename to the pinned name itself goes through.

Because `set_device_name` and its `SetValue` handler ignore the failures, a
host that renames the guest is told it worked, and the name stays.
lockdownd logs `SCPreferencesSetComputerName failed (…): Permission denied`.

## Injection

Both spawn hooks insert `/usr/lib/libdevicename.dylib` into
`/usr/libexec/configd` and `/usr/libexec/lockdownd` (`vpIsDeviceNameTarget` in
`Shared/InjectionEnvironment.h`). lockdownd also takes `libmisfix.dylib`, so
`vpInsertedLibrariesFor` returns every library for a path and lockdownd starts
with
`DYLD_INSERT_LIBRARIES=/usr/lib/SystemHook-vphone.dylib:/usr/lib/libmisfix.dylib:/usr/lib/libdevicename.dylib`.
A job launchd spawns itself goes through the launchd hook; one started through
`xpcproxy` goes through SystemHook. Either way it gets both libraries, and an
environment that already names some of them gains only the missing ones.

The interposes reach configd's and lockdownd's calls because both are
standalone images binding through their own imports. A call made inside the
shared cache is not rebound (see "An interpose does not cross the shared
cache" in `0_binary_patch_comparison.md`). The library checks
`getprogname()` and acts only in configd or lockdownd.

The library ships with `system-launchdaemons-boot-environment`. configd and
lockdownd pick it up when they next start, which in practice is the next boot.

## Assumptions to confirm

- Root processes can read `vphone-device-name` from `IODeviceTree:/options` as
  the host writes it, bare or under the GUID.
- lockdownd can read it too. If it cannot, renames reach `preferences.plist`,
  but configd still publishes the pinned name.
- PreferencesMonitor is the only publisher of `Setup:/System`.
- Settings' General → About → Name goes through lockdownd. If Settings writes
  the preferences itself, it is not refused, but configd still publishes the
  pinned name.
- configd starts after `/private/var` is mounted, so its log lines are kept.
  The pin does not depend on the log.

## Verification

On a test VM named, for example, `Lab Phone`:

1. `/var/mobile/Library/Caches/vphone-launchdhook-injection.log` or
   `vphone-systemhook-spawn.log` shows `inserted+devicename` for configd and
   `inserted+misfix+devicename` for lockdownd.
2. `/var/mobile/Library/Caches/vphone-devicename.log` has
   `configd pinned name "Lab Phone"` and `published Setup:/System ComputerName
   "Lab Phone"`.
3. `ideviceinfo -k DeviceName`, `xcrun devicectl list devices` and DeviceHub
   show `Lab Phone`. So does Settings → General → About.
4. `idevicename Other` returns, and `ideviceinfo -k DeviceName` still says
   `Lab Phone`. The log has `lockdownd refused
   SCPreferencesSetComputerName("Other")`. `preferences.plist` keeps the name
   it had before.
5. After `vm rename` to another name and a reboot, every view shows the new
   name.

Host-side checks need no guest: `make -C VPhoneGuestComponents
test-injection-environment test-devicename` covers target matching,
lockdownd's two libraries, the NVRAM value's decoding, the publication
rewrite and the rename decision.

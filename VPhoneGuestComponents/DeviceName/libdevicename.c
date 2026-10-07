// libdevicename.c — pin the guest's device name to the one the host chose,
// and refuse renaming it inside the guest.
//
// ## Where the name lives
//
// The device name is `System/System/ComputerName` in
// /private/var/preferences/SystemConfiguration/preferences.plist. configd
// (/usr/libexec/configd, a standalone image) publishes it into the dynamic
// store as `Setup:/System`, and every reader goes through the store:
// lockdownd's `copy_device_name` (`SCDynamicStoreCopyComputerName`, what
// lockdown `GetValue DeviceName`, Finder and Xcode see), MobileGestalt's
// UserAssignedDeviceName and UIDevice.name. Renames come in through lockdownd's
// `set_device_name`, which calls `SCPreferencesSetComputerName`,
// `SCPreferencesSetHostName` and `SCPreferencesSetLocalHostName` (its only
// callers of them) and commits.
//
// ## The channel
//
// Before each boot with the feature on, the host writes NVRAM variable
// `vphone-device-name`: the name's UTF-8 bytes, no terminator. With it off the
// host removes it. The guest reads it as the `IODeviceTree:/options` property
// of that name. Absent, empty or invalid (DeviceNamePolicy.c) means the feature
// is off, and every interpose here passes its call through unchanged.
//
// ## configd: the published name is the pinned one
//
// configd's preferences monitor (`updateConfiguration` in configd's
// PreferencesMonitor, statically linked into configd; 24A435:
// 0x100062098..0x100062d00) flattens `SCPreferencesGetValue(prefs,
// kSCPrefSystem)` into `Setup:/...` keys, compares them with what the store
// already has (`SCDynamicStoreCopyMultiple("^Setup:.*")`), leaves out the keys
// that did not change, and publishes the rest with one
// `SCDynamicStoreSetMultiple(store, keysToSet, keysToRemove, NULL)`.
//
// The pin goes in at that publication, not at the preferences read:
// `SCDynamicStoreSetMultiple` is interposed and, for a call that touches the
// `Setup:` domain, `Setup:/System`'s ComputerName becomes the pinned name
// (VPDeviceNameCreatePinnedPublication). When the call leaves the key out
// because it did not change, the store's current value is read and pinned if it
// does not already say so, and when it removes the key it is set instead. So a
// guest whose preferences never had a name gets the pinned one too.
// `SCDynamicStoreSetValue` of `Setup:/System` is pinned the same way, though no
// configd caller is known to set that key on its own.
//
// Substituting the `kSCPrefSystem` value from `SCPreferencesGetValue` would be
// read by the same flattening, but configd also reads that value to write it
// back: the monitor's model-change path (24A435 sub_10006155c) does
// `SCPreferencesGetValue(prefs, kSCPrefSystem)`,
// `__SCNetworkConfigurationSaveModel`, `SCPreferencesSetValue(prefs,
// kSCPrefSystem, same)`, which would commit the pinned name to disk. The
// publication route never changes preferences.plist, so turning the feature off
// brings the guest's own name back on the next boot.
//
// set-hostname's `__SCPreferencesCopyComputerName` reads the preferences file
// directly, to derive a DNS host name from a reverse lookup; it is not a
// display name and is left alone.
//
// ## lockdownd: renames are refused
//
// While a name is pinned, `SCPreferencesSetComputerName` with any other name
// returns false with `kSCStatusAccessError`, and the host name and local host
// name setters that follow on the same preferences object do too, so the
// preferences keep their name. A rename to the pinned name itself goes through.
// `set_device_name` only logs each setter's failure and its SetValue handler
// ignores the result, so a host that renames sees success and the name stays.
// lockdownd's startup naming (`MarketingDeviceFamilyName` when the store has
// no name) is refused the same way if it runs before configd has published;
// once configd has, lockdownd finds a name and does not try.
//
// ## Reach
//
// configd and lockdownd are standalone images, so their imports bind through
// dyld's interposing table; calls inside the shared cache do not, which is why
// the hooks sit on the daemons' own imports. Both spawn hooks insert this into
// those two processes only (`vpIsDeviceNameTarget` in
// Shared/InjectionEnvironment.h); lockdownd takes it after libmisfix. Each
// interpose checks which of the two it is in.
//
// ## Assumptions to confirm on a guest
//
//   - root processes read `vphone-device-name` from IODeviceTree:/options as
//     written by the host (bare name, or under Apple's NVRAM GUID, both tried);
//   - configd's PreferencesMonitor is the only publisher of `Setup:/System`;
//   - lockdownd may read NVRAM. If it cannot, its interposes see no pinned name
//     and pass renames through to preferences.plist, while configd still
//     publishes the pinned name;
//   - Settings' General > About > Name goes through lockdownd. If it writes the
//     preferences itself, configd still publishes the pinned name.

#include "DeviceNamePolicy.h"

#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOKitLib.h>
#include <fcntl.h>
#include <pthread.h>
#include <stdarg.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

// MARK: - SystemConfiguration

// Exported by SystemConfiguration on iOS, but its headers mark them
// unavailable there, so they are declared here.
typedef const struct __SCDynamicStore *VPSCDynamicStoreRef;
typedef const struct __SCPreferences *VPSCPreferencesRef;

extern Boolean SCDynamicStoreSetMultiple(VPSCDynamicStoreRef store, CFDictionaryRef keysToSet,
                                         CFArrayRef keysToRemove, CFArrayRef keysToNotify);
extern Boolean SCDynamicStoreSetValue(VPSCDynamicStoreRef store, CFStringRef key, CFPropertyListRef value);
extern CFPropertyListRef SCDynamicStoreCopyValue(VPSCDynamicStoreRef store, CFStringRef key);
extern Boolean SCPreferencesSetComputerName(VPSCPreferencesRef prefs, CFStringRef name, CFStringEncoding encoding);
extern Boolean SCPreferencesSetHostName(VPSCPreferencesRef prefs, CFStringRef name);
extern Boolean SCPreferencesSetLocalHostName(VPSCPreferencesRef prefs, CFStringRef name);
// SCPrivate.h; what SCError() returns next.
extern void _SCErrorSet(int error);

// SystemConfiguration.h: "Permission denied".
#define VP_SC_STATUS_ACCESS_ERROR 1003

// Apple's NVRAM variable GUID, for a host that writes the name under it.
#define VP_APPLE_NVRAM_GUID "7C436110-AB2A-4BBB-A880-FE41995C9F82"

// MARK: - Log

// configd and lockdownd both run as root, but the mode keeps the log open to
// the other guest libraries' writers, as in SystemHook. Bounded twice: lines
// per process, and the file's size, since configd republishes on every
// preferences change for the life of the guest.
#define VP_LOG_PATH "/var/mobile/Library/Caches/vphone-devicename.log"
#define VP_LOG_MAX_LINES 64
#define VP_LOG_MAX_BYTES (256 * 1024)

static void vpLog(const char *format, ...) __attribute__((format(printf, 1, 2)));
static void vpLog(const char *format, ...) {
    static atomic_int lines;
    if (atomic_fetch_add(&lines, 1) >= VP_LOG_MAX_LINES)
        return;
    int fd = open(VP_LOG_PATH, O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC, 0666);
    if (fd < 0)
        return;
    fchmod(fd, 0666);
    struct stat info;
    if (fstat(fd, &info) == 0 && info.st_size < VP_LOG_MAX_BYTES) {
        char line[768];
        va_list arguments;
        va_start(arguments, format);
        vsnprintf(line, sizeof(line), format, arguments);
        va_end(arguments);
        dprintf(fd, "pid=%d %s %s\n", getpid(), getprogname(), line);
    }
    close(fd);
}

// A name for the log, truncated to fit.
static const char *vpDescribe(CFStringRef string, char *buffer, size_t size) {
    if (!string)
        return "<null>";
    if (!CFStringGetCString(string, buffer, (CFIndex)size, kCFStringEncodingUTF8))
        snprintf(buffer, size, "<unprintable>");
    return buffer;
}

// MARK: - Pinned Name

enum { VPRoleOther, VPRoleConfigd, VPRoleLockdownd };

static int vpRole;
static CFStringRef vpPinned;
static pthread_once_t vpPinnedOnce = PTHREAD_ONCE_INIT;

static CFStringRef vpCopyNVRAMName(void) {
    io_registry_entry_t options = IORegistryEntryFromPath(kIOMainPortDefault, "IODeviceTree:/options");
    if (options == MACH_PORT_NULL)
        return NULL;
    static const CFStringRef names[] = {
        CFSTR(VP_DEVICE_NAME_NVRAM_VARIABLE),
        CFSTR(VP_APPLE_NVRAM_GUID ":" VP_DEVICE_NAME_NVRAM_VARIABLE),
    };
    CFStringRef name = NULL;
    for (size_t index = 0; !name && index < sizeof(names) / sizeof(names[0]); index++) {
        CFTypeRef property = IORegistryEntryCreateCFProperty(options, names[index], kCFAllocatorDefault, 0);
        if (!property)
            continue;
        name = VPDeviceNameCreateFromProperty(property);
        if (!name)
            vpLog("NVRAM %s is present but not a valid name; nothing is pinned",
                  VP_DEVICE_NAME_NVRAM_VARIABLE);
        CFRelease(property);
        break;
    }
    IOObjectRelease(options);
    return name;
}

static void vpResolvePinned(void) {
    vpPinned = vpCopyNVRAMName();
    char buffer[VP_DEVICE_NAME_MAX_BYTES + 1];
    if (vpPinned)
        vpLog("pinned name \"%s\"", vpDescribe(vpPinned, buffer, sizeof(buffer)));
}

// The pinned name for the process this hook acts in, or NULL to pass through.
// Read once: the host writes it before boot and nothing changes it after.
static CFStringRef vpPinnedName(int role) {
    if (vpRole != role)
        return NULL;
    pthread_once(&vpPinnedOnce, vpResolvePinned);
    return vpPinned;
}

// MARK: - configd

static Boolean vpSetMultiple(VPSCDynamicStoreRef store, CFDictionaryRef keysToSet, CFArrayRef keysToRemove,
                             CFArrayRef keysToNotify) {
    CFStringRef name = vpPinnedName(VPRoleConfigd);
    if (!name || !VPDeviceNameIsSetupPublication(keysToSet, keysToRemove))
        return SCDynamicStoreSetMultiple(store, keysToSet, keysToRemove, keysToNotify);
    CFPropertyListRef stored = VPDeviceNameNeedsStoredSystem(keysToSet, keysToRemove)
                                   ? SCDynamicStoreCopyValue(store, VP_DEVICE_NAME_SYSTEM_KEY)
                                   : NULL;
    CFDictionaryRef set = NULL;
    CFArrayRef remove = NULL;
    const Boolean changed = VPDeviceNameCreatePinnedPublication(keysToSet, keysToRemove, stored, name, &set, &remove);
    if (stored)
        CFRelease(stored);
    if (!changed)
        return SCDynamicStoreSetMultiple(store, keysToSet, keysToRemove, keysToNotify);
    const Boolean result = SCDynamicStoreSetMultiple(store, set, remove, keysToNotify);
    char buffer[VP_DEVICE_NAME_MAX_BYTES + 1];
    vpLog("published Setup:/System ComputerName \"%s\" result=%d", vpDescribe(name, buffer, sizeof(buffer)),
          result);
    CFRelease(set);
    if (remove)
        CFRelease(remove);
    return result;
}

static Boolean vpSetValue(VPSCDynamicStoreRef store, CFStringRef key, CFPropertyListRef value) {
    CFStringRef name = vpPinnedName(VPRoleConfigd);
    if (!name || !key || !CFEqual(key, VP_DEVICE_NAME_SYSTEM_KEY))
        return SCDynamicStoreSetValue(store, key, value);
    CFDictionaryRef pinned = VPDeviceNameCreatePinnedSystem(value, name);
    if (!pinned)
        return SCDynamicStoreSetValue(store, key, value);
    const Boolean result = SCDynamicStoreSetValue(store, key, pinned);
    char buffer[VP_DEVICE_NAME_MAX_BYTES + 1];
    vpLog("set Setup:/System ComputerName \"%s\" result=%d", vpDescribe(name, buffer, sizeof(buffer)), result);
    CFRelease(pinned);
    return result;
}

// MARK: - lockdownd

// The preferences object whose ComputerName was just refused on this thread.
// set_device_name makes one per rename and calls the three setters on it in
// turn, so the host name setters follow the ComputerName decision.
static __thread VPSCPreferencesRef vpRefusedPreferences;

static Boolean vpRefuse(const char *setter, CFStringRef requested) {
    char wanted[VP_DEVICE_NAME_MAX_BYTES + 1];
    char pinned[VP_DEVICE_NAME_MAX_BYTES + 1];
    vpLog("refused %s(\"%s\"): the name is pinned to \"%s\"", setter, vpDescribe(requested, wanted, sizeof(wanted)),
          vpDescribe(vpPinned, pinned, sizeof(pinned)));
    _SCErrorSet(VP_SC_STATUS_ACCESS_ERROR);
    return false;
}

static Boolean vpSetComputerName(VPSCPreferencesRef prefs, CFStringRef name, CFStringEncoding encoding) {
    CFStringRef pinned = vpPinnedName(VPRoleLockdownd);
    if (VPDeviceNameAllowsRename(pinned, name)) {
        vpRefusedPreferences = NULL;
        return SCPreferencesSetComputerName(prefs, name, encoding);
    }
    vpRefusedPreferences = prefs;
    return vpRefuse("SCPreferencesSetComputerName", name);
}

static Boolean vpSetHostName(VPSCPreferencesRef prefs, CFStringRef name) {
    if (vpPinnedName(VPRoleLockdownd) && prefs && prefs == vpRefusedPreferences)
        return vpRefuse("SCPreferencesSetHostName", name);
    return SCPreferencesSetHostName(prefs, name);
}

static Boolean vpSetLocalHostName(VPSCPreferencesRef prefs, CFStringRef name) {
    if (vpPinnedName(VPRoleLockdownd) && prefs && prefs == vpRefusedPreferences) {
        // The last of set_device_name's three setters.
        vpRefusedPreferences = NULL;
        return vpRefuse("SCPreferencesSetLocalHostName", name);
    }
    return SCPreferencesSetLocalHostName(prefs, name);
}

// MARK: - Load

__attribute__((constructor)) static void vpDeviceNameInit(void) {
    const char *name = getprogname();
    vpRole = name && strcmp(name, "configd") == 0     ? VPRoleConfigd
             : name && strcmp(name, "lockdownd") == 0 ? VPRoleLockdownd
                                                      : VPRoleOther;
}

int vphone_devicename_version(void) { return 1; }

// Easy to change: each row is one import of configd or lockdownd. Which of
// the two a row acts in is decided by `vpPinnedName`'s role check.
__attribute__((used, section("__DATA,__interpose"))) static const struct {
    const void *replacement;
    const void *replacee;
} vpInterpose[] = {
    {(const void *)vpSetMultiple, (const void *)SCDynamicStoreSetMultiple},
    {(const void *)vpSetValue, (const void *)SCDynamicStoreSetValue},
    {(const void *)vpSetComputerName, (const void *)SCPreferencesSetComputerName},
    {(const void *)vpSetHostName, (const void *)SCPreferencesSetHostName},
    {(const void *)vpSetLocalHostName, (const void *)SCPreferencesSetLocalHostName},
};

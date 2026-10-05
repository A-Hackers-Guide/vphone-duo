#ifndef VPHONE_INJECTION_ENVIRONMENT_H
#define VPHONE_INJECTION_ENVIRONMENT_H

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#define VP_SYSTEM_HOOK "/usr/lib/SystemHook-vphone.dylib"

// The MIS hook. Inserted only into the processes that evaluate a code
// signature or a provisioning profile — see `vpIsMISFixTarget` below —
// rather than carried by every spawn. This insertion is the only way it gets
// there: no guest binary carries a load command for it.
#define VP_MIS_FIX "/usr/lib/libmisfix.dylib"

static int vpPathHasSuffix(const char *path, const char *suffix) {
    size_t length = path ? strlen(path) : 0;
    size_t want = strlen(suffix);
    return length >= want && strcmp(path + length - want, suffix) == 0;
}

// The processes that evaluate a code signature or a provisioning profile, and
// so the ones that have to agree about what device this is and what signatures
// are acceptable, plus the two that tell the host which device this is.
// Everything else spawns without libmisfix.
//
//   installd    runs `+[MICodeSigningVerifier
//               _validateSignatureAndCopyInfoForURL:withOptions:error:]`, which
//               is in MobileInstallation and calls libmis. This is the install.
//   misagent    installs the embedded profile and checks ProvisionedDevices.
//   SpringBoard asks MIS again at launch; without the hook an installed app is
//               refused there with 0xE8008026.
//   lockdownd   answers lockdown `GetValue UniqueDeviceID` (usbmuxd clients).
//   remoted     puts `UniqueDeviceID` in the RSD handshake (CoreDevice, Xcode).
//               These two get the MobileGestalt override only; the MIS detours
//               stand down in them (`MISFixProcessOnlyNeedsIdentity`).
//
// Both spawn hooks ask this, because the targets do not share a parent:
// installd and misagent are started through xpcproxy, which carries
// SystemHook, and SpringBoard (`POSIXSpawnType` App) is started by launchd
// itself, which carries only the launchd hook. Asking in one of them alone is
// what left SpringBoard without libmisfix.
//
// Matched on the end of the path so a bootstrap or cryptex copy of the same
// binary is caught too.
static int vpIsMISFixTarget(const char *path) {
    if (!path)
        return 0;
    return vpPathHasSuffix(path, "/usr/libexec/installd") ||
           vpPathHasSuffix(path, "/usr/libexec/misagent") ||
           vpPathHasSuffix(path, "/usr/libexec/lockdownd") ||
           vpPathHasSuffix(path, "/usr/libexec/remoted") ||
           vpPathHasSuffix(path, "/SpringBoard.app/SpringBoard");
}

// The library to insert alongside SystemHook for `path`, or NULL. NULL as well
// when the dylib is not installed, so a guest without it never gets a
// DYLD_INSERT_LIBRARIES entry naming a missing file.
static const char *vpMISFixFor(const char *path) {
    return vpIsMISFixTarget(path) && access(VP_MIS_FIX, R_OK) == 0 ? VP_MIS_FIX : NULL;
}

// The battery health hook, which fills in the health half of the internal
// battery's power source description; see
// BatteryHealthFix/libbatteryhealthfix.c. Inserted rather than loaded by
// SystemHook because it interposes: the table has to be in place before
// BatteryUsageUI.bundle is bound.
#define VP_BATTERY_HEALTH_FIX "/usr/lib/libbatteryhealthfix.dylib"

// Settings, the one process that shows Battery Health. Asked by both spawn
// hooks, like the MIS targets, so it holds whichever of them starts the app.
static int vpIsBatteryHealthFixTarget(const char *path) {
    return path && vpPathHasSuffix(path, "/Preferences.app/Preferences");
}

static const char *vpBatteryHealthFixFor(const char *path) {
    return vpIsBatteryHealthFixTarget(path) && access(VP_BATTERY_HEALTH_FIX, R_OK) == 0
               ? VP_BATTERY_HEALTH_FIX
               : NULL;
}

// The one library, if any, the spawn hooks insert beside SystemHook for
// `path`. The MIS and battery health targets do not overlap.
static const char *vpInsertedLibraryFor(const char *path) {
    const char *library = vpMISFixFor(path);
    return library ? library : vpBatteryHealthFixFor(path);
}

typedef struct {
    char **values;
    char *hook;
    char *root;
} VPInjectionEnvironment;

static const char *vpEnvValue(char *const env[], const char *name) {
    if (!env)
        return NULL;
    size_t length = strlen(name);
    for (size_t i = 0; env[i]; i++) {
        if (strncmp(env[i], name, length) == 0 && env[i][length] == '=')
            return env[i] + length + 1;
    }
    return NULL;
}

static int vpEnvIsOne(char *const env[], const char *name) {
    const char *value = vpEnvValue(env, name);
    return value && strcmp(value, "1") == 0;
}

static int vpInjectionDisabled(char *const env[]) {
    return vpEnvIsOne(env, "DISABLE_TWEAKS") || vpEnvIsOne(env, "_SafeMode") || vpEnvIsOne(env, "_MSSafeMode");
}

// Whether `library` is already one of the colon-separated entries in `paths`.
static int vpListHasPath(const char *paths, const char *library) {
    if (!paths || !library)
        return 0;
    const size_t length = strlen(library);
    for (const char *start = paths; *start;) {
        const char *end = strchr(start, ':');
        size_t count = end ? (size_t)(end - start) : strlen(start);
        if (count == length && strncmp(start, library, count) == 0)
            return 1;
        if (!end)
            break;
        start = end + 1;
    }
    return 0;
}

static int vpHasHook(const char *paths) {
    return vpListHasPath(paths, VP_SYSTEM_HOOK);
}

// Keep the bootstrap path with the injected hooks across xpcproxy's new envp.
//
// `extra` is a second library to insert alongside the system hook, or NULL.
// Only the ones not already listed are added, so this is safe to run over an
// environment that has been through here before.
static VPInjectionEnvironment vpInsertHooks(char *const env[], const char *root, const char *extra) {
    VPInjectionEnvironment result = {0};
    size_t count = 0;
    size_t dyld = (size_t)-1;
    size_t jbRoot = (size_t)-1;
    if (env) {
        while (count < 4096 && env[count]) {
            if (strncmp(env[count], "DYLD_INSERT_LIBRARIES=", 22) == 0)
                dyld = count;
            if (strncmp(env[count], "VPHONE_JB_ROOT=", 15) == 0)
                jbRoot = count;
            count++;
        }
        if (count == 4096)
            return result;
    }
    const char *existing = dyld == (size_t)-1 ? NULL : env[dyld] + 22;
    int addHook = !vpListHasPath(existing, VP_SYSTEM_HOOK);
    int addExtra = extra && *extra && !vpListHasPath(existing, extra);
    int addRoot = root && *root &&
                  (jbRoot == (size_t)-1 || strcmp(env[jbRoot] + 15, root) != 0);
    if (!addHook && !addExtra && !addRoot)
        return result;
    if (addHook || addExtra) {
        size_t size = strlen("DYLD_INSERT_LIBRARIES=") + 1;
        if (addHook)
            size += strlen(VP_SYSTEM_HOOK) + 1;
        if (addExtra)
            size += strlen(extra) + 1;
        if (existing && *existing)
            size += strlen(existing) + 1;
        result.hook = malloc(size);
        if (!result.hook)
            return result;
        // The inserted libraries go first, before whatever the caller already
        // had, so their interposes are in place before anything else loads.
        int written = snprintf(result.hook, size, "DYLD_INSERT_LIBRARIES=");
        if (addHook)
            written += snprintf(result.hook + written, size - (size_t)written, "%s", VP_SYSTEM_HOOK);
        if (addExtra)
            written += snprintf(result.hook + written, size - (size_t)written, "%s%s",
                                addHook ? ":" : "", extra);
        if (existing && *existing)
            snprintf(result.hook + written, size - (size_t)written, ":%s", existing);
    }
    if (addRoot) {
        size_t size = strlen("VPHONE_JB_ROOT=") + strlen(root) + 1;
        result.root = malloc(size);
        if (!result.root) {
            free(result.hook);
            return (VPInjectionEnvironment){0};
        }
        snprintf(result.root, size, "VPHONE_JB_ROOT=%s", root);
    }
    // Either addition rewrites the whole DYLD_INSERT_LIBRARIES entry, so an
    // environment that already names SystemHook still gets the extra library.
    const int addLibraries = addHook || addExtra;
    result.values = calloc(count + (addLibraries && dyld == (size_t)-1) +
                               (addRoot && jbRoot == (size_t)-1) + 1, sizeof(char *));
    if (!result.values) {
        free(result.hook);
        free(result.root);
        return (VPInjectionEnvironment){0};
    }
    for (size_t i = 0; i < count; i++)
        result.values[i] = addLibraries && i == dyld ? result.hook :
                           addRoot && i == jbRoot ? result.root : env[i];
    if (addLibraries && dyld == (size_t)-1)
        result.values[count++] = result.hook;
    if (addRoot && jbRoot == (size_t)-1)
        result.values[count] = result.root;
    return result;
}

static void vpFreeEnvironment(VPInjectionEnvironment *environment) {
    free(environment->values);
    free(environment->hook);
    free(environment->root);
}

#endif

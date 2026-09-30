#ifndef VPHONE_INJECTION_ENVIRONMENT_H
#define VPHONE_INJECTION_ENVIRONMENT_H

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define VP_SYSTEM_HOOK "/usr/lib/SystemHook-vphone.dylib"

// The MIS hook. Inserted only into the processes that evaluate a code
// signature or a provisioning profile — see `vpIsMISFixTarget` in
// SystemHook-vphone.c — rather than carried by every spawn.
//
// It is inserted rather than linked, and that distinction is the point.
// `cfw install` used to give installd and misagent an LC_LOAD_WEAK_DYLIB, which
// makes the hook a dependency of the main executable. That is enough to
// interpose calls the main executable makes itself, which is why misagent's
// UDID override worked, and it is *not* enough for a call made between two
// shared-cache images: installd's profile check is
// `+[MICodeSigningVerifier _validateSignatureAndCopyInfoForURL:withOptions:error:]`
// in MobileInstallation calling libmis, with installd's own image not involved,
// and that one kept seeing the guest's real UDID. DYLD_INSERT_LIBRARIES loads
// the hook ahead of everything else, which is where an interpose covers the
// cache's own uses of a symbol too.
#define VP_MIS_FIX "/usr/lib/libmisfix.dylib"

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
    result.values = calloc(count + (addHook && dyld == (size_t)-1) +
                               (addRoot && jbRoot == (size_t)-1) + 1, sizeof(char *));
    if (!result.values) {
        free(result.hook);
        free(result.root);
        return (VPInjectionEnvironment){0};
    }
    for (size_t i = 0; i < count; i++)
        result.values[i] = addHook && i == dyld ? result.hook :
                           addRoot && i == jbRoot ? result.root : env[i];
    if (addHook && dyld == (size_t)-1)
        result.values[count++] = result.hook;
    if (addRoot && jbRoot == (size_t)-1)
        result.values[count] = result.root;
    return result;
}

// The system hook alone, which is what every spawn gets.
static VPInjectionEnvironment vpInsertHook(char *const env[], const char *root) {
    return vpInsertHooks(env, root, NULL);
}

static void vpFreeEnvironment(VPInjectionEnvironment *environment) {
    free(environment->values);
    free(environment->hook);
    free(environment->root);
}

#endif

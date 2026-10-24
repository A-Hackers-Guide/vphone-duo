// HomePod's cryptexd stages DDI assets on the cloudOS-backed Data volume.
// Treat EPERM from setting class D like its existing ENOTSUP fallback.
// Retain ticket/signature/root-hash validation, use until-reboot DDI lifetime,
// and tolerate the research SEP's unsupported manifest digest storage for DDI.
#include <CoreFoundation/CoreFoundation.h>
#include <errno.h>
#include <fcntl.h>
#include <stdarg.h>
#include <stdatomic.h>
#include <stdio.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>
#include <xpc/xpc.h>

#define VP_STRINGIFY_INNER(value) #value
#define VP_STRINGIFY(value) VP_STRINGIFY_INNER(value)

#ifdef VP_CRYPTEX_STAGING_TESTING
extern int vpTestFcntl(int fd, int command, ...);
extern CFErrorRef vpTestSignatureLockWithSEP(void *signature, int infoFD);
#define VP_FCNTL vpTestFcntl
#define VP_FCNTL_SYMBOL "_vpTestFcntl"
#define VP_SEP_LOCK vpTestSignatureLockWithSEP
#else
#define VP_FCNTL fcntl
#define VP_FCNTL_SYMBOL "_fcntl"
extern CFErrorRef cryptex_signature_lock_with_sep(void *signature, int infoFD);
#define VP_SEP_LOCK cryptex_signature_lock_with_sep

static void vpLog(const char *message) {
    int saved = errno;
    int fd = open("/var/mobile/Library/Caches/vphone-cryptex-staging.log",
                  O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC, 0644);
    if (fd >= 0) {
        dprintf(fd, "pid=%d %s\n", getpid(), message);
        close(fd);
    }
    errno = saved;
}

__attribute__((constructor)) static void vpLoaded(void) {
    vpLog("cryptex staging compatibility loaded");
}
#endif

// The native caller passes the already imported info asset's descriptor after
// cryptex_signature_lock succeeds. Read without changing its file position.
static bool vpIsDeveloperInfo(int fd) {
    struct stat status;
    if (fstat(fd, &status) != 0 || !S_ISREG(status.st_mode) ||
        status.st_size <= 0 || status.st_size > 65536)
        return false;
    CFMutableDataRef bytes = CFDataCreateMutable(kCFAllocatorDefault, status.st_size);
    if (!bytes) return false;
    CFDataSetLength(bytes, status.st_size);
    bool matched = false;
    if (pread(fd, CFDataGetMutableBytePtr(bytes), status.st_size, 0) == status.st_size) {
        CFPropertyListRef info = CFPropertyListCreateWithData(kCFAllocatorDefault, bytes,
                                                            kCFPropertyListImmutable, NULL, NULL);
        if (info && CFGetTypeID(info) == CFDictionaryGetTypeID()) {
            CFTypeRef name = CFDictionaryGetValue(info, CFSTR("CFBundleIdentifier"));
            CFTypeRef path = CFDictionaryGetValue(info, CFSTR("RequiredMountPath"));
            CFTypeRef developer = CFDictionaryGetValue(info, CFSTR("DeveloperModeRequired"));
            matched = name && CFEqual(name, CFSTR("com.apple.MobileAsset.DDI")) &&
                      path && CFEqual(path, CFSTR("/System/Developer")) &&
                      developer && CFEqual(developer, kCFBooleanTrue);
        }
        if (info) CFRelease(info);
    }
    CFRelease(bytes);
    return matched;
}

static CFErrorRef vpSignatureLockWithSEP(void *signature, int infoFD) {
    CFErrorRef error = VP_SEP_LOCK(signature, infoFD);
    if (error && CFErrorGetCode(error) == ENOTRECOVERABLE &&
        CFEqual(CFErrorGetDomain(error), CFSTR("com.apple.security.cryptex.posix")) &&
        vpIsDeveloperInfo(infoFD)) {
#ifndef VP_CRYPTEX_STAGING_TESTING
        vpLog("DDI SEP digest storage unavailable; retaining verified until-reboot mount");
#endif
        CFRelease(error);
        return NULL;
    }
    return error;
}

// cryptexd reads these fields from the remote install argv before building its
// core object. Select the DDI GenericDmg tuple from the signed build identity;
// ordinary cryptexes and every authentication option retain their input values.
// Use until-reboot lifetime when SEP digest storage is unavailable.
static uint64_t vpDictionaryGetUInt64(xpc_object_t dictionary, const char *key) {
    uint64_t value = xpc_dictionary_get_uint64(dictionary, key);
    if (strcmp(key, "persistence") != 0 && strcmp(key, "nonce-persistence") != 0)
        return value;
    if (xpc_dictionary_get_int64(dictionary, "image-type-index") != 10)
        return value;
    xpc_object_t properties = xpc_dictionary_get_dictionary(dictionary, "cryptex1-properties");
    if (!properties ||
        !xpc_dictionary_get_bool(properties, "Cryptex1,UseProductClass") ||
        xpc_dictionary_get_uint64(properties, "Cryptex1,SubType") != 2 ||
        xpc_dictionary_get_uint64(properties, "Cryptex1,NonceDomain") != 4)
        return value;
    // Preserve invalid options so cryptexd still diagnoses malformed requests.
    if (value > (strcmp(key, "persistence") == 0 ? 2u : 1u))
        return value;
#ifndef VP_CRYPTEX_STAGING_TESTING
    if (value != 0)
        vpLog(strcmp(key, "persistence") == 0
              ? "DDI persistence mapped to until reboot"
              : "DDI nonce persistence mapped to until reboot");
#endif
    return 0;
}

__attribute__((used, noinline)) static int vpProtectionFcntl(int fd, int command, ...) {
    va_list arguments;
    va_start(arguments, command);
    int protectionClass = va_arg(arguments, int);
    va_end(arguments);
    int result = VP_FCNTL(fd, command, protectionClass);
    if (result == -1 && errno == EPERM && protectionClass == 4 /* class D */) {
#ifndef VP_CRYPTEX_STAGING_TESTING
        static atomic_bool logged;
        if (!atomic_exchange(&logged, 1))
            vpLog("F_SETPROTECTIONCLASS EPERM, reported as ENOTSUP");
#endif
        errno = ENOTSUP;
    }
    return result;
}

// Apple's arm64 variadic arguments are stack-passed. Tail-forward every other
// command verbatim, including commands with no third argument, integer
// arguments and pointers. Reading one universal va_arg would be undefined for
// no-argument commands and would not preserve all fcntl argument types.
__attribute__((naked)) static int vpFcntl(int fd, int command, ...) {
    __asm__("cmp w1, #" VP_STRINGIFY(F_SETPROTECTIONCLASS) "\n"
            "b.ne 1f\n"
            "b _vpProtectionFcntl\n"
            "1: b " VP_FCNTL_SYMBOL "\n");
}

#ifndef VP_CRYPTEX_STAGING_TESTING
__attribute__((used, section("__DATA,__interpose"))) static const struct {
    const void *replacement;
    const void *original;
} vpInterpose[] = {
    { (const void *)&vpFcntl, (const void *)&fcntl },
    { (const void *)&vpDictionaryGetUInt64, (const void *)&xpc_dictionary_get_uint64 },
    { (const void *)&vpSignatureLockWithSEP, (const void *)&cryptex_signature_lock_with_sep },
};
#endif

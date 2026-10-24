// HomePod port of the existing installation-proxy UserManager exception.
// This image has no spawn, jetsam, display, or iPhone environment hooks.
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

#ifndef VP_HOMEPOD_PERSONA_TESTING
typedef struct { unsigned int val[8]; } vp_audit_token_t;
#endif
#include "../LaunchHook/InstallCoordinationPersona.h"

#ifdef VP_HOMEPOD_PERSONA_TESTING
#define VP_SANDBOX_SYMBOL "_vpTestSandboxCheck"
#else
#define VP_SANDBOX_SYMBOL "_sandbox_check_by_audit_token"
extern int sandbox_check_by_audit_token(vp_audit_token_t token, const char *operation,
                                        unsigned int filter, ...);
#endif

__attribute__((used, noinline)) static int vpHomePodPersonaAllowed(
    const vp_audit_token_t *token, const char *operation, unsigned int filter, const void *name) {
    int saved = errno;
#ifdef VP_HOMEPOD_PERSONA_TESTING
    int allowed = vpInstallProxyPersonaAllowed(*token, operation, filter, name);
#else
    int allowed = getpid() == 1 && vpInstallProxyPersonaAllowed(*token, operation, filter, name);
    if (allowed) {
        int fd = open("/var/mobile/Library/Caches/vphone-homepod-persona.log",
                      O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC, 0644);
        if (fd >= 0) {
            dprintf(fd, "allow pid=%u mach-lookup %s\n", token->val[5], VP_PERSONA_SERVICE);
            close(fd);
        }
    }
#endif
    errno = saved;
    return allowed;
}

// Apple's arm64 ABI passes the 32-byte token indirectly in x0, the remaining
// fixed arguments in x1/x2, and variadic arguments on the stack. Inspect only
// the first stack slot, and tail-forward rejected calls with their original
// stack and registers. In particular, no va_arg is read for no-argument calls.
__attribute__((naked)) static int vpHomePodSandboxCheck(vp_audit_token_t token,
                                                       const char *operation, unsigned int filter, ...) {
    __asm__("stp x29, x30, [sp, #-48]!\n"
            "mov x29, sp\n"
            "stp x0, x1, [sp, #16]\n"
            "str x2, [sp, #32]\n"
            "ldr x3, [sp, #48]\n"
            "bl _vpHomePodPersonaAllowed\n"
            "cmp w0, #0\n"
            "ldp x0, x1, [sp, #16]\n"
            "ldr x2, [sp, #32]\n"
            "ldp x29, x30, [sp], #48\n"
            "b.eq 1f\n"
            "mov w0, #0\n"
            "ret\n"
            "1: b " VP_SANDBOX_SYMBOL "\n");
}

#ifndef VP_HOMEPOD_PERSONA_TESTING
__attribute__((used, section("__DATA,__interpose"))) static const struct {
    const void *replacement;
    const void *original;
} vpInterpose = { (const void *)&vpHomePodSandboxCheck, (const void *)&sandbox_check_by_audit_token };
#endif

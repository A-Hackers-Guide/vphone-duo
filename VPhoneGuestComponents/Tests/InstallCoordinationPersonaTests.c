#include <assert.h>
#include <limits.h>
#include <stdint.h>
#include <stdarg.h>
#include <errno.h>
#include <stdio.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>
typedef struct { unsigned int val[8]; } vp_audit_token_t;
static int test_stat(const char *, struct stat *);
#define lstat test_stat
#define proc_pidpath test_path
#define csops_audittoken test_csops
#include "../LaunchHook/InstallCoordinationPersona.h"
static int markerMissing, wrongPath, staleToken, wrongIdentity;
static mode_t markerMode = S_IFREG | 0644;
static uid_t markerOwner;
static int test_stat(const char *path, struct stat *info) {
    assert(!strcmp(path, VP_PERSONA_MARKER));
    memset(info, 0, sizeof(*info));
    info->st_mode = markerMode;
    info->st_uid = markerOwner;
    return markerMissing ? -1 : 0;
}
int test_path(int pid, void *buffer, uint32_t size) {
    assert(pid == 404);
    return snprintf(buffer, size, "%s", wrongPath ? "/tmp/installcoordination_proxy" : VP_INSTALL_PROXY);
}
int test_csops(pid_t pid, unsigned int op, void *buffer, size_t size, vp_audit_token_t *token) {
    assert(pid == 404 && op == 11 && token->val[7] == 42);
    if (staleToken) return -1;
    snprintf((char *)buffer + 8, size - 8, "%s", wrongIdentity ? "other" : "com.apple.installcoordination_proxy");
    return 0;
}
#define VP_HOMEPOD_PERSONA_TESTING
#include "../HomePodInstallPersona/libvphoneinstallpersona.c"

int vpTestSandboxCheck(vp_audit_token_t token, const char *operation, unsigned int filter, ...) {
    assert(token.val[5] == 404 && token.val[7] == 42);
    if (filter == 99) {
        va_list arguments;
        va_start(arguments, filter);
        assert(va_arg(arguments, const char *) == operation);
        assert(va_arg(arguments, int) == 567);
        assert(va_arg(arguments, void *) == &markerMode);
        va_end(arguments);
    }
    errno = EACCES;
    return 73;
}
int main(void) {
    vp_audit_token_t token = {{0}};
    token.val[5] = 404;
    token.val[7] = 42;
    for (unsigned int filter = 0; filter < 32; filter++)
        assert(vpInstallProxyPersonaAllowed(token, "mach-lookup", filter, VP_PERSONA_SERVICE) ==
               (filter == 2 || filter == 3 || filter == 12));
    assert(!vpInstallProxyPersonaAllowed(token, NULL, 2, VP_PERSONA_SERVICE));
    assert(!vpInstallProxyPersonaAllowed(token, "mach-register", 2, VP_PERSONA_SERVICE));
    assert(!vpInstallProxyPersonaAllowed(token, "mach-lookup", 2, NULL));
    assert(!vpInstallProxyPersonaAllowed(token, "mach-lookup", 2, "com.apple.other"));
    int *failures[] = {&markerMissing, &wrongPath, &staleToken, &wrongIdentity};
    for (size_t i = 0; i < sizeof(failures)/sizeof(failures[0]); i++) {
        *failures[i] = 1;
        assert(!vpInstallProxyPersonaAllowed(token, "mach-lookup", 2, VP_PERSONA_SERVICE));
        *failures[i] = 0;
    }
    markerMode = S_IFLNK | 0644;
    assert(!vpInstallProxyPersonaAllowed(token, "mach-lookup", 2, VP_PERSONA_SERVICE));
    markerMode = S_IFREG | 0664;
    assert(!vpInstallProxyPersonaAllowed(token, "mach-lookup", 2, VP_PERSONA_SERVICE));
    markerMode = S_IFREG | 0644;
    markerOwner = 501;
    assert(!vpInstallProxyPersonaAllowed(token, "mach-lookup", 2, VP_PERSONA_SERVICE));
    markerOwner = 0;
    errno = EDOM;
    assert(vpHomePodSandboxCheck(token, "mach-lookup", 2, VP_PERSONA_SERVICE) == 0);
    assert(errno == EDOM);
    assert(vpHomePodSandboxCheck(token, NULL, 0) == 73 && errno == EACCES);
    assert(vpHomePodSandboxCheck(token, "mach-lookup", 2, "com.apple.other") == 73);
    const char *op = "other-operation";
    assert(vpHomePodSandboxCheck(token, op, 99, op, 567, &markerMode) == 73);
    puts("InstallCoordination persona lookup scope tests passed");
}

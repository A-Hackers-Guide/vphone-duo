#include "../Shared/InjectionEnvironment.h"
#include <assert.h>

#define EXTRA "/usr/lib/extra.dylib"

static const char *value(char *const env[], const char *name) { return vpEnvValue(env, name); }

static size_t count(char *const env[]) {
    size_t total = 0;
    while (env[total])
        total++;
    return total;
}

// A spawn with no DYLD_INSERT_LIBRARIES gets both, SystemHook first.
static void insertsBoth(void) {
    char *env[] = {"HOME=/var/mobile", NULL};
    VPInjectionEnvironment result = vpInsertHooks(env, NULL, EXTRA);
    assert(result.values);
    assert(count(result.values) == 2);
    assert(strcmp(value(result.values, "DYLD_INSERT_LIBRARIES"), VP_SYSTEM_HOOK ":" EXTRA) == 0);
    vpFreeEnvironment(&result);
}

// The environment already names SystemHook — launchd passes its own to a job
// it starts directly — and the extra library must still be added.
static void addsExtraBesideAnExistingHook(void) {
    char *env[] = {"DYLD_INSERT_LIBRARIES=" VP_SYSTEM_HOOK, "HOME=/var/mobile", NULL};
    VPInjectionEnvironment result = vpInsertHooks(env, NULL, EXTRA);
    assert(result.values);
    assert(count(result.values) == 2);
    assert(strcmp(value(result.values, "DYLD_INSERT_LIBRARIES"), EXTRA ":" VP_SYSTEM_HOOK) == 0);
    vpFreeEnvironment(&result);
}

static void leavesACompleteEnvironmentAlone(void) {
    char *env[] = {"DYLD_INSERT_LIBRARIES=" VP_SYSTEM_HOOK ":" EXTRA, NULL};
    VPInjectionEnvironment result = vpInsertHooks(env, NULL, EXTRA);
    assert(!result.values);
    vpFreeEnvironment(&result);
}

static void namesTheMISFixTargets(void) {
    assert(vpIsMISFixTarget("/usr/libexec/installd"));
    assert(vpIsMISFixTarget("/usr/libexec/misagent"));
    assert(vpIsMISFixTarget("/usr/libexec/lockdownd"));
    assert(vpIsMISFixTarget("/usr/libexec/remoted"));
    assert(vpIsMISFixTarget("/System/Library/CoreServices/SpringBoard.app/SpringBoard"));
    assert(!vpIsMISFixTarget("/usr/libexec/xpcproxy"));
    assert(!vpIsMISFixTarget("/usr/libexec/installdx"));
    assert(!vpIsMISFixTarget(NULL));
}

int main(void) {
    insertsBoth();
    addsExtraBesideAnExistingHook();
    leavesACompleteEnvironmentAlone();
    namesTheMISFixTargets();
    puts("InjectionEnvironmentTests: ok");
    return 0;
}

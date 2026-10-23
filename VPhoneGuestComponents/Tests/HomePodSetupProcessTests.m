#import "HomePodSetupProcesses.h"
#include <assert.h>
#include <errno.h>
#include <signal.h>
#include <string.h>

static BOOL running, initialLaunchInFlight, wrongPath, identityChanges, denied, refusesSignal, enumerationFails;
static NSUInteger ticks, signals, pathReads;

static int listPIDs(uint32_t type, uint32_t user, void *buffer, int capacity) {
    assert(type == 4 && user == 501); // Never enumerate arbitrary users.
    if (enumerationFails) return 0;
    pid_t pids[] = {7, 188}; // mobile's unrelated process and HPSetup.
    int bytes = (running || initialLaunchInFlight) ? sizeof(pids) : sizeof(pid_t);
    if (!buffer) return bytes;
    assert(capacity >= bytes);
    memcpy(buffer, pids, (size_t)bytes);
    return bytes;
}
static int processPath(int pid, void *buffer, uint32_t capacity) {
    const char *path = "/usr/bin/unrelated";
    if (pid == 188) {
        pathReads++;
        if (denied) { errno = EPERM; return 0; }
        if (!running) { errno = ESRCH; return 0; }
        path = wrongPath || (identityChanges && pathReads > 1)
            ? "/tmp/HPSetup" : "/Applications/HPSetup.app/HPSetup";
    }
    assert(strlen(path) + 1 < capacity);
    strcpy(buffer, path);
    return (int)strlen(path);
}
static int signalProcess(pid_t pid, int signal) {
    assert(pid == 188 && signal == SIGTERM); // No other process or stronger signal.
    signals++;
    if (!refusesSignal) running = NO;
    return 0;
}
static void reset(void) {
    running = initialLaunchInFlight = wrongPath = identityChanges = denied = refusesSignal = enumerationFails = NO;
    ticks = signals = pathReads = 0;
}

int main(void) {
    @autoreleasepool {
        VPHomePodSetupProcessAPI api = {listPIDs, processPath, signalProcess};
        NSError *error = nil;
        void (^wait)(void) = ^{
            ticks++;
            if (initialLaunchInFlight && ticks == 2) { running = YES; initialLaunchInFlight = NO; }
        };
        reset();
        assert(VPHomePodSetupStopProcesses(api, 501, 10, wait, &error));
        assert(signals == 0 && ticks == 4); // Helper first: bounded quiet interval.
        reset(); running = YES;
        assert(VPHomePodSetupStopProcesses(api, 501, 10, wait, &error));
        assert(signals == 1 && !running); // SoundBoard/HPSetup first: graceful exit observed.
        reset(); initialLaunchInFlight = YES;
        assert(VPHomePodSetupStopProcesses(api, 501, 10, wait, &error));
        assert(signals == 1 && !running); // Already-requested launch appears during quiet interval.
        reset(); running = YES; wrongPath = YES;
        assert(VPHomePodSetupStopProcesses(api, 501, 10, wait, &error));
        assert(signals == 0); // Basename alone cannot authorize termination.
        reset(); running = YES; identityChanges = YES;
        assert(VPHomePodSetupStopProcesses(api, 501, 10, wait, &error));
        assert(signals == 0); // Revalidate identity immediately before signal.
        reset(); running = YES; denied = YES;
        assert(!VPHomePodSetupStopProcesses(api, 501, 10, wait, &error));
        assert(signals == 0 && error); // An unreadable identity is not proof setup is gone.
        reset(); running = YES; refusesSignal = YES;
        assert(!VPHomePodSetupStopProcesses(api, 501, 6, wait, &error));
        assert(signals == 1 && ticks == 6 && running); // Timeout; never escalate/repeatedly signal.
        reset(); enumerationFails = YES;
        assert(!VPHomePodSetupStopProcesses(api, 501, 10, wait, &error));
        assert(signals == 0);
        reset();
        assert(!VPHomePodSetupStopProcesses(api, 0, 10, wait, &error));
        assert(signals == 0); // Root/arbitrary-user execution refused.
        NSLog(@"HomePod setup process ordering and identity tests passed");
    }
    return 0;
}

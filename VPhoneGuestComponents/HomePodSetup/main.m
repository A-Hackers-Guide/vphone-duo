// Run as mobile by launchd: the donor SoundBoard writes current-user values,
// and SetupAssistant's launch sentinel is a per-user POSIX named semaphore.
#import "HomePodSetupState.h"
#import "HomePodSetupProcesses.h"
#import <CoreFoundation/CoreFoundation.h>
#import <dlfcn.h>
#import <notify.h>
#import <signal.h>
#import <unistd.h>

int main(void) {
    @autoreleasepool {
        if (getuid() != 501 || geteuid() != 501) {
            NSLog(@"HomePod setup maintenance must run as mobile (501).");
            return 1;
        }
        NSString *directory = @"/var/mobile/Library/Application Support/vphone";
        NSURL *journal = [NSURL fileURLWithPath:[directory stringByAppendingPathComponent:@"HomePodSetupOriginal.plist"]];
        NSDictionary *policy = [NSDictionary dictionaryWithContentsOfFile:@"/usr/share/vphone/HomePodSetup.plist"];
        BOOL enabled = [policy[@"Enabled"] isEqual:@YES];
        BOOL hadJournal = [NSFileManager.defaultManager fileExistsAtPath:journal.path];
        if (!enabled && !hadJournal) return 0;

        void *framework = dlopen("/System/Library/PrivateFrameworks/SetupAssistant.framework/SetupAssistant", RTLD_NOW);
        void (*prepare)(void) = framework ? dlsym(framework, "BYSetupAssistantPrepareLaunchSentinel") : NULL;
        BOOL (*needsSetup)(void) = framework ? dlsym(framework, "BYSetupAssistantNeedsToRun") : NULL;
        BOOL (*completed)(void) = framework ? dlsym(framework, "BYSetupAssistantHasCompletedInitialRun") : NULL;
        CFStringRef *finishedNotification = framework ? dlsym(framework, "BYSetupAssistantFinishedDarwinNotification") : NULL;
        NSError *error = nil;
        BOOL success = NO;
        if (!prepare || !needsSetup || !completed || !finishedNotification || !*finishedNotification) {
            error = [NSError errorWithDomain:@"com.vphone.homepod-setup" code:2
                                    userInfo:@{NSLocalizedDescriptionKey: @"Donor SetupAssistant completion APIs are unavailable."}];
        } else {
            CFStringRef domain = CFSTR("com.apple.purplebuddy");
            CFPreferencesSynchronize(domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost);
            NSMutableDictionary *current = [NSMutableDictionary dictionary];
            for (NSString *key in VPHomePodSetupKeys()) {
                id value = CFBridgingRelease(CFPreferencesCopyValue((__bridge CFStringRef)key, domain,
                    kCFPreferencesCurrentUser, kCFPreferencesAnyHost));
                if (value) current[key] = value;
            }
            success = VPHomePodSetupUpdate(enabled, journal, current, ^(NSString *key, id value) {
                CFPreferencesSetValue((__bridge CFStringRef)key, (__bridge CFPropertyListRef)value, domain,
                    kCFPreferencesCurrentUser, kCFPreferencesAnyHost);
            }, ^BOOL {
                return CFPreferencesSynchronize(domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost);
            }, &error);
            if (success) {
                // The stock function publishes the setup state notification and
                // prepares/clears the semaphore. SoundBoard then uses its own
                // setup-gated initialization; do not fake a HomeKit home here.
                BOOL setupDone = CFPreferencesGetAppBooleanValue(CFSTR("SetupDone"), domain, NULL);
                BOOL allSteps = CFPreferencesGetAppBooleanValue(CFSTR("SetupFinishedAllSteps"), domain, NULL);
                BOOL forceNoBuddy = CFPreferencesGetAppBooleanValue(CFSTR("ForceNoBuddy"), domain, NULL);
                BOOL expectedNeedsSetup = enabled ? NO : !setupDone && !forceNoBuddy;
                BOOL expectedCompleted = enabled ? YES : allSteps || forceNoBuddy;
                success = VPHomePodSetupPrepare(enabled, expectedNeedsSetup, expectedCompleted,
                    ^BOOL { return needsSetup(); }, ^BOOL { return completed(); }, ^{ prepare(); }, ^BOOL {
                    // Prepare already publishes when creating the sentinel.
                    // Only replay an existing sentinel's event, using the
                    // donor export rather than duplicating its notification.
                    char name[512];
                    return CFStringGetCString(*finishedNotification, name, sizeof(name), kCFStringEncodingUTF8)
                        && notify_post(name) == NOTIFY_STATUS_OK;
                }, &error);
                if (success) {
                    if (enabled) {
                        // A pending HPSetup session owns separate assistant/
                        // voice-trigger assertions; native _setupFinished does
                        // not tear that process down, so finish it gracefully.
                        void *processLibrary = dlopen("/usr/lib/libproc.dylib", RTLD_NOW);
                        VPHomePodSetupProcessAPI api = {
                            .listPIDs = processLibrary ? dlsym(processLibrary, "proc_listpids") : NULL,
                            .processPath = processLibrary ? dlsym(processLibrary, "proc_pidpath") : NULL,
                            .signalProcess = kill,
                        };
                        success = VPHomePodSetupStopProcesses(api, getuid(), 50, ^{
                            NSDate *until = [NSDate dateWithTimeIntervalSinceNow:0.1];
                            [NSRunLoop.currentRunLoop runUntilDate:until];
                            NSTimeInterval remaining = until.timeIntervalSinceNow;
                            if (remaining > 0) [NSThread sleepForTimeInterval:remaining];
                        }, &error);
                    } else {
                        // Keep the inverse through the native sentinel transition,
                        // including failures that need a later launchd retry.
                        success = [NSFileManager.defaultManager removeItemAtURL:journal error:&error];
                    }
                }
            }
        }
        [NSFileManager.defaultManager createDirectoryAtPath:directory withIntermediateDirectories:YES
                                               attributes:@{NSFilePosixPermissions: @0700} error:NULL];
        NSMutableDictionary *status = [@{@"Enabled": @(enabled), @"Succeeded": @(success), @"Updated": NSDate.date} mutableCopy];
        if (needsSetup) status[@"NeedsSetup"] = @(needsSetup());
        if (completed) status[@"CompletedInitialRun"] = @(completed());
        if (error) status[@"Error"] = error.localizedDescription;
        [status writeToFile:[directory stringByAppendingPathComponent:@"HomePodSetupStatus.plist"] atomically:YES];
        NSLog(@"HomePod setup maintenance: %@", status);
        return success ? 0 : 1;
    }
}

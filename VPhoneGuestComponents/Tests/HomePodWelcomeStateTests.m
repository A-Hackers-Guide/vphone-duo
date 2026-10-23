#import "VPHomePodWelcomeState.h"
#include <dispatch/dispatch.h>
#include <signal.h>
#include <stdlib.h>
#include <sys/resource.h>
#include <sys/stat.h>
#include <unistd.h>

#define CHECK(...) do { if (!(__VA_ARGS__)) { NSLog(@"Failed at line %d: %s", __LINE__, #__VA_ARGS__); abort(); } } while (0)

static NSString *directory(NSString *root, NSString *name) {
    return [root stringByAppendingPathComponent:name];
}

static void makeDirectory(NSString *path) {
    CHECK([NSFileManager.defaultManager createDirectoryAtPath:path withIntermediateDirectories:YES attributes:nil error:NULL]);
}

static BOOL withWritesPrevented(BOOL (^operation)(void)) {
    // Force a real regular-file persistence failure, including when the test
    // runs as root. Restore the process limit/handler before inspecting errors.
    struct rlimit original;
    CHECK(getrlimit(RLIMIT_FSIZE, &original) == 0);
    struct rlimit limited = original;
    limited.rlim_cur = 0;
    void (*handler)(int) = signal(SIGXFSZ, SIG_IGN);
    CHECK(handler != SIG_ERR && setrlimit(RLIMIT_FSIZE, &limited) == 0);
    BOOL result = operation();
    CHECK(setrlimit(RLIMIT_FSIZE, &original) == 0);
    CHECK(signal(SIGXFSZ, handler) != SIG_ERR);
    return result;
}

int main(void) {
    @autoreleasepool {
        NSString *root = [NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
        makeDirectory(root);
        NSError *error = nil;

        // Production adds an identity directory below HomePodWelcome. Every
        // newly-created ancestor entry must persist before the claim succeeds.
        NSString *nestedPath = directory(root, @"new-vphone/HomePodWelcome/device-identity");
        VPHomePodWelcomeState *nested = [[VPHomePodWelcomeState alloc] initWithDirectory:nestedPath];
        CHECK([nested claimWithError:&error] && !error);
        for (NSString *path in @[directory(root, @"new-vphone"), directory(root, @"new-vphone/HomePodWelcome"), nestedPath]) {
            struct stat metadata;
            CHECK(stat(path.fileSystemRepresentation, &metadata) == 0 && S_ISDIR(metadata.st_mode));
        }
        CHECK(![[[VPHomePodWelcomeState alloc] initWithDirectory:nestedPath] claimWithError:&error] && !error);

        // An existing containing ancestor can be a system alias (/var on
        // Apple platforms). It is not the control directory and may be followed.
        NSString *ancestor = directory(root, @"existing-ancestor");
        NSString *alias = directory(root, @"ancestor-alias");
        makeDirectory(ancestor);
        CHECK(symlink(ancestor.fileSystemRepresentation, alias.fileSystemRepresentation) == 0);
        NSString *aliasedNestedPath = directory(alias, @"HomePodWelcome/device-identity");
        VPHomePodWelcomeState *aliasedNested = [[VPHomePodWelcomeState alloc] initWithDirectory:aliasedNestedPath];
        CHECK([aliasedNested claimWithError:&error] && !error);
        CHECK([NSFileManager.defaultManager fileExistsAtPath:directory(ancestor, @"HomePodWelcome/device-identity/Claim.plist")]);

        NSString *oncePath = directory(root, @"once");
        VPHomePodWelcomeState *once = [[VPHomePodWelcomeState alloc] initWithDirectory:oncePath];
        CHECK([once claimWithError:&error] && !error);
        NSString *claimPath = directory(oncePath, @"Claim.plist");
        NSData *claim = [NSData dataWithContentsOfFile:claimPath];
        CHECK(claim.length > 0);
        struct stat claimMetadata, controlMetadata;
        CHECK(lstat(claimPath.fileSystemRepresentation, &claimMetadata) == 0);
        CHECK((claimMetadata.st_mode & 0777) == 0600 && claimMetadata.st_uid == geteuid());
        CHECK(lstat(oncePath.fileSystemRepresentation, &controlMetadata) == 0);
        CHECK((controlMetadata.st_mode & 0777) == 0700 && controlMetadata.st_uid == geteuid());
        CHECK(![once claimWithError:&error] && !error);
        VPHomePodWelcomeState *restarted = [[VPHomePodWelcomeState alloc] initWithDirectory:oncePath];
        CHECK(![restarted claimWithError:&error] && !error); // Process/boot restart preserves consumption.

        CHECK([once writeStatus:@"playing" fields:@{@"Tone": @1, @"State": @"cannot override", @"Updated": @0} error:&error]);
        NSString *statusPath = directory(oncePath, @"Status.plist");
        NSDictionary *status = [NSDictionary dictionaryWithContentsOfFile:statusPath];
        CHECK([status[@"State"] isEqual:@"playing"] && [status[@"Updated"] isKindOfClass:NSDate.class]);
        CHECK([status[@"Tone"] isEqual:@1]);
        CHECK([once writeStatus:@"failed" fields:@{@"Error": @"speech unavailable"} error:&error]);
        status = [NSDictionary dictionaryWithContentsOfFile:statusPath];
        CHECK([status[@"State"] isEqual:@"failed"] && [status[@"Error"] isEqual:@"speech unavailable"]);
        CHECK(![once writeStatus:@"failed" fields:@{@"Invalid": [NSObject new]} error:&error] && error);
        CHECK([[NSDictionary dictionaryWithContentsOfFile:statusPath] isEqual:status]);
        CHECK([[NSData dataWithContentsOfFile:claimPath] isEqual:claim]);
        struct stat afterStatus;
        CHECK(lstat(claimPath.fileSystemRepresentation, &afterStatus) == 0 && afterStatus.st_ino == claimMetadata.st_ino);
        CHECK(lstat(statusPath.fileSystemRepresentation, &afterStatus) == 0 && (afterStatus.st_mode & 0777) == 0600);
        CHECK(![restarted claimWithError:&error] && !error); // Progress cannot clear or replace the claim.

        for (NSData *malformed in @[[NSData data], [@"partial plist" dataUsingEncoding:NSUTF8StringEncoding]]) {
            NSString *path = directory(root, NSUUID.UUID.UUIDString);
            makeDirectory(path);
            CHECK([malformed writeToFile:directory(path, @"Claim.plist") atomically:YES]);
            VPHomePodWelcomeState *state = [[VPHomePodWelcomeState alloc] initWithDirectory:path];
            CHECK(![state claimWithError:&error] && !error);
            CHECK([[NSData dataWithContentsOfFile:directory(path, @"Claim.plist")] isEqual:malformed]);
        }

        NSString *target = directory(root, @"symlink-target");
        makeDirectory(target);
        NSString *linkedDirectory = directory(root, @"linked-directory");
        CHECK(symlink(target.fileSystemRepresentation, linkedDirectory.fileSystemRepresentation) == 0);
        VPHomePodWelcomeState *linked = [[VPHomePodWelcomeState alloc] initWithDirectory:linkedDirectory];
        CHECK(![linked claimWithError:&error] && error);
        CHECK(![linked writeStatus:@"waiting" fields:@{} error:&error] && error);
        CHECK(![NSFileManager.defaultManager fileExistsAtPath:directory(target, @"Claim.plist")]);
        CHECK(![NSFileManager.defaultManager fileExistsAtPath:directory(target, @"Status.plist")]);

        NSString *sentinel = directory(root, @"sentinel");
        NSData *untouched = [@"untouched" dataUsingEncoding:NSUTF8StringEncoding];
        CHECK([untouched writeToFile:sentinel atomically:YES]);
        NSString *linkedClaimPath = directory(root, @"linked-claim");
        makeDirectory(linkedClaimPath);
        CHECK(symlink(sentinel.fileSystemRepresentation, directory(linkedClaimPath, @"Claim.plist").fileSystemRepresentation) == 0);
        VPHomePodWelcomeState *linkedClaim = [[VPHomePodWelcomeState alloc] initWithDirectory:linkedClaimPath];
        CHECK(![linkedClaim claimWithError:&error] && error);
        CHECK([[NSData dataWithContentsOfFile:sentinel] isEqual:untouched]);
        NSString *linkedStatusPath = directory(root, @"linked-status");
        makeDirectory(linkedStatusPath);
        CHECK(symlink(sentinel.fileSystemRepresentation, directory(linkedStatusPath, @"Status.plist").fileSystemRepresentation) == 0);
        VPHomePodWelcomeState *linkedStatus = [[VPHomePodWelcomeState alloc] initWithDirectory:linkedStatusPath];
        CHECK(![linkedStatus writeStatus:@"waiting" fields:@{} error:&error] && error);
        CHECK([[NSData dataWithContentsOfFile:sentinel] isEqual:untouched]);

        NSString *failedPath = directory(root, @"failed-write");
        VPHomePodWelcomeState *failed = [[VPHomePodWelcomeState alloc] initWithDirectory:failedPath];
        CHECK([failed writeStatus:@"waiting" fields:@{} error:&error]);
        __block NSError *writeError = nil;
        CHECK(!withWritesPrevented(^BOOL { return [failed claimWithError:&writeError]; }));
        CHECK(writeError && [NSFileManager.defaultManager fileExistsAtPath:directory(failedPath, @"Claim.plist")]);
        CHECK(![[[VPHomePodWelcomeState alloc] initWithDirectory:failedPath] claimWithError:&error] && !error);
        NSData *priorStatus = [NSData dataWithContentsOfFile:directory(failedPath, @"Status.plist")];
        CHECK(!withWritesPrevented(^BOOL { return [failed writeStatus:@"completed" fields:@{} error:&writeError]; }));
        CHECK(writeError && [[NSData dataWithContentsOfFile:directory(failedPath, @"Status.plist")] isEqual:priorStatus]);
        CHECK(![failed claimWithError:&error] && !error); // Failed persistence is fail-closed, never a retry permission.

        NSString *notDirectory = directory(root, @"regular-file");
        CHECK([untouched writeToFile:notDirectory atomically:YES]);
        VPHomePodWelcomeState *invalid = [[VPHomePodWelcomeState alloc] initWithDirectory:notDirectory];
        CHECK(![invalid claimWithError:&error] && error);
        CHECK(![[[VPHomePodWelcomeState alloc] initWithDirectory:@"relative"] claimWithError:&error] && error);

        NSString *concurrentPath = directory(root, @"concurrent/HomePodWelcome/device-identity");
        dispatch_group_t group = dispatch_group_create();
        NSObject *lock = [NSObject new];
        __block NSUInteger winners = 0, failures = 0;
        for (NSUInteger index = 0; index < 32; index++) {
            dispatch_group_async(group, dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^{
                @autoreleasepool {
                    VPHomePodWelcomeState *state = [[VPHomePodWelcomeState alloc] initWithDirectory:concurrentPath];
                    NSError *failure = nil;
                    BOOL claimed = [state claimWithError:&failure];
                    @synchronized (lock) {
                        winners += claimed ? 1 : 0;
                        failures += failure ? 1 : 0;
                    }
                }
            });
        }
        CHECK(dispatch_group_wait(group, dispatch_time(DISPATCH_TIME_NOW, 10 * NSEC_PER_SEC)) == 0);
        CHECK(winners == 1 && failures == 0);
        CHECK(![[[VPHomePodWelcomeState alloc] initWithDirectory:concurrentPath] claimWithError:&error] && !error);

        CHECK([NSFileManager.defaultManager removeItemAtPath:root error:&error]);
        NSLog(@"HomePod welcome durable claim and status tests passed");
    }
    return 0;
}

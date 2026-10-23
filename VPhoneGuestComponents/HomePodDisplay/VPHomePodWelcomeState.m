#import "VPHomePodWelcomeState.h"
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

static BOOL VPWelcomeError(NSError **error, int code, NSString *operation, NSString *path) {
    if (error) *error = [NSError errorWithDomain:NSPOSIXErrorDomain code:code
                                      userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"%@: %s", operation, strerror(code)],
                                                 NSFilePathErrorKey: path}];
    return NO;
}

static BOOL VPWelcomeWrite(int descriptor, NSData *data, NSError **error, NSString *path) {
    const uint8_t *bytes = data.bytes;
    NSUInteger remaining = data.length;
    while (remaining) {
        ssize_t count = write(descriptor, bytes, remaining);
        if (count < 0 && errno == EINTR) continue;
        if (count <= 0) return VPWelcomeError(error, count < 0 ? errno : EIO, @"Write welcome state", path);
        bytes += count;
        remaining -= (NSUInteger)count;
    }
    return YES;
}

static BOOL VPWelcomeSync(int descriptor, NSError **error, NSString *path) {
    int result;
    do { result = fsync(descriptor); } while (result != 0 && errno == EINTR);
    return result == 0 || VPWelcomeError(error, errno, @"Persist welcome state", path);
}

@implementation VPHomePodWelcomeState {
    NSString *_directory;
}

- (instancetype)initWithDirectory:(NSString *)directory {
    if ((self = [super init])) _directory = [directory copy];
    return self;
}

- (int)openDirectoryWithError:(NSError **)error {
    if (!_directory.isAbsolutePath || [_directory rangeOfString:@"\0"].location != NSNotFound) {
        VPWelcomeError(error, EINVAL, @"Invalid welcome state directory", _directory);
        return -1;
    }
    int flags = O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC;
    int descriptor = open(_directory.fileSystemRepresentation, flags);
    int openError = descriptor < 0 ? errno : 0;
    BOOL created = openError == ENOENT;
    NSMutableArray<NSString *> *parentsToSync = NSMutableArray.array;
    if (created) {
        // Capture the missing chain before recursive mkdir makes every level
        // appear to exist. Each new directory's entry belongs to its parent;
        // syncing only the final identity directory's parent misses newly
        // created HomePodWelcome/vphone entries farther up the chain.
        NSString *cursor = _directory;
        for (;;) {
            struct stat ancestor;
            if (stat(cursor.fileSystemRepresentation, &ancestor) == 0) {
                if (!S_ISDIR(ancestor.st_mode)) {
                    VPWelcomeError(error, ENOTDIR, @"Inspect welcome state ancestor", cursor);
                    return -1;
                }
                break;
            }
            int code = errno;
            if (code != ENOENT) {
                VPWelcomeError(error, code, @"Inspect welcome state ancestor", cursor);
                return -1;
            }
            NSString *parent = cursor.stringByDeletingLastPathComponent;
            if (!parent.length || [parent isEqual:cursor]) {
                VPWelcomeError(error, EINVAL, @"Invalid welcome state ancestor", cursor);
                return -1;
            }
            [parentsToSync addObject:parent];
            cursor = parent;
        }
        // Only directory creation uses a pathname. All control-file operations
        // use the pinned, non-symlink directory descriptor below.
        [NSFileManager.defaultManager createDirectoryAtPath:_directory withIntermediateDirectories:YES
                                               attributes:@{NSFilePosixPermissions: @0700} error:NULL];
        descriptor = open(_directory.fileSystemRepresentation, flags);
        openError = descriptor < 0 ? errno : 0;
    }
    if (descriptor < 0) {
        VPWelcomeError(error, openError, @"Open welcome state directory", _directory);
        return -1;
    }
    struct stat metadata;
    if (fstat(descriptor, &metadata) != 0) {
        VPWelcomeError(error, errno, @"Inspect welcome state directory", _directory);
        close(descriptor);
        return -1;
    }
    if (!S_ISDIR(metadata.st_mode) || metadata.st_uid != geteuid()) {
        VPWelcomeError(error, EPERM, @"Welcome state directory must belong to the current user", _directory);
        close(descriptor);
        return -1;
    }
    if (fchmod(descriptor, 0700) != 0) {
        VPWelcomeError(error, errno, @"Protect welcome state directory", _directory);
        close(descriptor);
        return -1;
    }
    for (NSString *parent in parentsToSync) {
        // Follow ordinary ancestor aliases such as /var. The control directory
        // itself and its claim remain pinned with O_NOFOLLOW independently.
        int parentDescriptor = open(parent.fileSystemRepresentation, O_RDONLY | O_DIRECTORY | O_CLOEXEC);
        if (parentDescriptor < 0) {
            VPWelcomeError(error, errno, @"Open welcome state parent", parent);
            close(descriptor);
            return -1;
        }
        BOOL persisted = VPWelcomeSync(parentDescriptor, error, parent);
        close(parentDescriptor);
        if (!persisted) { close(descriptor); return -1; }
    }
    return descriptor;
}

- (BOOL)claimWithError:(NSError **)error {
    if (error) *error = nil;
    int directory = [self openDirectoryWithError:error];
    if (directory < 0) return NO;
    int descriptor = openat(directory, "Claim.plist", O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0600);
    if (descriptor < 0) {
        int code = errno;
        if (code == EEXIST) {
            struct stat entry;
            if (fstatat(directory, "Claim.plist", &entry, AT_SYMLINK_NOFOLLOW) != 0) code = errno;
            else if (S_ISLNK(entry.st_mode)) code = ELOOP;
            else { close(directory); return NO; } // Never parse, repair or overwrite a prior claim.
        }
        close(directory);
        return VPWelcomeError(error, code, @"Create exclusive welcome claim", _directory);
    }
    NSData *claim = [NSPropertyListSerialization dataWithPropertyList:@{@"Version": @1, @"Claimed": NSDate.date}
                                                               format:NSPropertyListBinaryFormat_v1_0 options:0 error:error];
    BOOL success = YES;
    if (fchmod(descriptor, 0600) != 0) success = VPWelcomeError(error, errno, @"Protect welcome claim", _directory);
    success = success && claim && VPWelcomeWrite(descriptor, claim, error, _directory)
        && VPWelcomeSync(descriptor, error, _directory) && VPWelcomeSync(directory, error, _directory);
    if (close(descriptor) != 0 && success) success = VPWelcomeError(error, errno, @"Close welcome claim", _directory);
    close(directory);
    // A failed write or sync may leave an empty/partial claim. Keep it: the
    // caller cannot safely treat an uncertain durable claim as replayable.
    return success;
}

- (BOOL)writeStatus:(NSString *)status fields:(NSDictionary *)fields error:(NSError **)error {
    if (error) *error = nil;
    if (![status isKindOfClass:NSString.class] || !status.length || ![fields isKindOfClass:NSDictionary.class]) {
        return VPWelcomeError(error, EINVAL, @"Invalid welcome status", _directory);
    }
    NSMutableDictionary *record = [fields mutableCopy];
    record[@"State"] = status;
    record[@"Updated"] = NSDate.date;
    if (![NSPropertyListSerialization propertyList:record isValidForFormat:NSPropertyListBinaryFormat_v1_0]) {
        return VPWelcomeError(error, EINVAL, @"Welcome status fields must be property-list values", _directory);
    }
    NSData *data = [NSPropertyListSerialization dataWithPropertyList:record format:NSPropertyListBinaryFormat_v1_0 options:0 error:error];
    if (!data) return NO;
    int directory = [self openDirectoryWithError:error];
    if (directory < 0) return NO;
    struct stat entry;
    if (fstatat(directory, "Status.plist", &entry, AT_SYMLINK_NOFOLLOW) == 0) {
        if (!S_ISREG(entry.st_mode)) {
            close(directory);
            return VPWelcomeError(error, ELOOP, @"Refuse non-regular welcome status", _directory);
        }
    } else if (errno != ENOENT) {
        int code = errno;
        close(directory);
        return VPWelcomeError(error, code, @"Inspect welcome status", _directory);
    }
    NSString *temporary = [NSString stringWithFormat:@".Status.%@.tmp", NSUUID.UUID.UUIDString];
    int descriptor = openat(directory, temporary.fileSystemRepresentation, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0600);
    if (descriptor < 0) {
        int code = errno;
        close(directory);
        return VPWelcomeError(error, code, @"Create welcome status", _directory);
    }
    BOOL success = YES;
    if (fchmod(descriptor, 0600) != 0) success = VPWelcomeError(error, errno, @"Protect welcome status", _directory);
    success = success && VPWelcomeWrite(descriptor, data, error, _directory) && VPWelcomeSync(descriptor, error, _directory);
    if (close(descriptor) != 0 && success) success = VPWelcomeError(error, errno, @"Close welcome status", _directory);
    if (success && renameat(directory, temporary.fileSystemRepresentation, directory, "Status.plist") != 0) {
        success = VPWelcomeError(error, errno, @"Replace welcome status", _directory);
    }
    if (success) success = VPWelcomeSync(directory, error, _directory);
    if (!success) unlinkat(directory, temporary.fileSystemRepresentation, 0);
    close(directory);
    return success;
}
@end

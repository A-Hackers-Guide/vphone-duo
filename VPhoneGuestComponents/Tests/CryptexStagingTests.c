// Exercise arm64 variadic forwarding and preserve every unrelated failure.
#include <assert.h>
#include <string.h>
#define VP_CRYPTEX_STAGING_TESTING
#include "../CryptexStagingFix/libvphonecryptexstaging.c"

static int returnedResult, returnedErrno, expectedCommand;
static int expectedInteger;
static void *expectedPointer;
static CFErrorRef sepError;

CFErrorRef vpTestSignatureLockWithSEP(void *signature, int infoFD) {
    assert(signature == (void *)123);
    return sepError ? (CFErrorRef)CFRetain(sepError) : NULL;
}

static void testSEPStorage(void) {
    FILE *file = tmpfile();
    assert(file);
    const char *xml = "<?xml version=\"1.0\"?><plist version=\"1.0\"><dict>"
        "<key>CFBundleIdentifier</key><string>com.apple.MobileAsset.DDI</string>"
        "<key>RequiredMountPath</key><string>/System/Developer</string>"
        "<key>DeveloperModeRequired</key><true/></dict></plist>";
    assert(fwrite(xml, 1, strlen(xml), file) == strlen(xml));
    fflush(file);
    int fd = fileno(file);
    assert(lseek(fd, 7, SEEK_SET) == 7);
    assert(vpIsDeveloperInfo(fd));
    assert(lseek(fd, 0, SEEK_CUR) == 7);
    sepError = CFErrorCreate(NULL, CFSTR("com.apple.security.cryptex.posix"), ENOTRECOVERABLE, NULL);
    assert(vpSignatureLockWithSEP((void *)123, fd) == NULL);
    CFRelease(sepError);
    sepError = CFErrorCreate(NULL, CFSTR("com.apple.security.cryptex.posix"), EACCES, NULL);
    CFErrorRef returned = vpSignatureLockWithSEP((void *)123, fd);
    assert(returned == sepError);
    CFRelease(returned);
    CFRelease(sepError);
    sepError = CFErrorCreate(NULL, kCFErrorDomainPOSIX, ENOTRECOVERABLE, NULL);
    returned = vpSignatureLockWithSEP((void *)123, fd);
    assert(returned == sepError);
    CFRelease(returned);
    CFRelease(sepError);
    sepError = CFErrorCreate(NULL, CFSTR("com.apple.security.cryptex.posix"), ENOTRECOVERABLE, NULL);
    // Wrong identifier, mount path, and missing Developer Mode requirement
    // must all preserve the native error, even with the same SEP failure.
    for (int i = 0; i < 3; i++) {
        char *changed = strdup(xml);
        assert(changed);
        const char *fields[] = { "com.apple.MobileAsset.DDI", "/System/Developer", "DeveloperModeRequired" };
        char *field = strstr(changed, fields[i]);
        assert(field);
        field[strlen(fields[i]) - 1] = 'X';
        assert(pwrite(fd, changed, strlen(changed), 0) == (ssize_t)strlen(changed));
        assert(!vpIsDeveloperInfo(fd));
        returned = vpSignatureLockWithSEP((void *)123, fd);
        assert(returned == sepError);
        CFRelease(returned);
        free(changed);
    }
    assert(ftruncate(fd, 0) == 0);
    assert(!vpIsDeveloperInfo(fd));
    returned = vpSignatureLockWithSEP((void *)123, fd);
    assert(returned == sepError);
    CFRelease(returned);
    CFRelease(sepError);
    sepError = NULL;
    assert(vpSignatureLockWithSEP((void *)123, fd) == NULL);
    fclose(file);
    assert(!vpIsDeveloperInfo(-1));
}

int vpTestFcntl(int fd, int command, ...) {
    assert(fd == 123);
    assert(command == expectedCommand);
    va_list arguments;
    va_start(arguments, command);
    if (command == F_SETPROTECTIONCLASS || command == F_DUPFD)
        assert(va_arg(arguments, int) == expectedInteger);
    else if (command == F_GETPATH)
        assert(va_arg(arguments, void *) == expectedPointer);
    else
        assert(command == F_GETFD);
    va_end(arguments);
    errno = returnedErrno;
    return returnedResult;
}

int main(void) {
    testSEPStorage();
    xpc_object_t request = xpc_dictionary_create(NULL, NULL, 0);
    xpc_object_t properties = xpc_dictionary_create(NULL, NULL, 0);
    xpc_dictionary_set_int64(request, "image-type-index", 10);
    xpc_dictionary_set_value(request, "cryptex1-properties", properties);
    xpc_dictionary_set_bool(properties, "Cryptex1,UseProductClass", true);
    xpc_dictionary_set_uint64(properties, "Cryptex1,SubType", 2);
    xpc_dictionary_set_uint64(properties, "Cryptex1,NonceDomain", 4);
    xpc_dictionary_set_uint64(request, "persistence", 2);
    xpc_dictionary_set_uint64(request, "nonce-persistence", 1);
    xpc_dictionary_set_uint64(request, "auth", 1);
    assert(vpDictionaryGetUInt64(request, "persistence") == 0);
    assert(vpDictionaryGetUInt64(request, "nonce-persistence") == 0);
    assert(vpDictionaryGetUInt64(request, "auth") == 1);
    assert(xpc_dictionary_get_uint64(request, "persistence") == 2);
    // Each tuple field is required; unrelated installs retain persistence.
    xpc_dictionary_set_uint64(properties, "Cryptex1,NonceDomain", 3);
    assert(vpDictionaryGetUInt64(request, "persistence") == 2);
    xpc_dictionary_set_uint64(properties, "Cryptex1,NonceDomain", 4);
    xpc_dictionary_set_uint64(properties, "Cryptex1,SubType", 1);
    assert(vpDictionaryGetUInt64(request, "persistence") == 2);
    xpc_dictionary_set_uint64(properties, "Cryptex1,SubType", 2);
    xpc_dictionary_set_bool(properties, "Cryptex1,UseProductClass", false);
    assert(vpDictionaryGetUInt64(request, "persistence") == 2);
    xpc_dictionary_set_bool(properties, "Cryptex1,UseProductClass", true);
    xpc_dictionary_set_int64(request, "image-type-index", 6);
    assert(vpDictionaryGetUInt64(request, "persistence") == 2);
    xpc_dictionary_set_int64(request, "image-type-index", 10);
    xpc_dictionary_set_uint64(request, "persistence", 3);
    xpc_dictionary_set_uint64(request, "nonce-persistence", 2);
    assert(vpDictionaryGetUInt64(request, "persistence") == 3);
    assert(vpDictionaryGetUInt64(request, "nonce-persistence") == 2);
    xpc_dictionary_set_value(request, "cryptex1-properties", NULL);
    xpc_dictionary_set_uint64(request, "persistence", 2);
    assert(vpDictionaryGetUInt64(request, "persistence") == 2);
    xpc_release(properties);
    xpc_release(request);
    expectedCommand = F_SETPROTECTIONCLASS;
    expectedInteger = 4;
    returnedResult = -1;
    returnedErrno = EPERM;
    assert(vpFcntl(123, expectedCommand, 4) == -1 && errno == ENOTSUP);
    expectedInteger = 3;
    assert(vpFcntl(123, expectedCommand, 3) == -1 && errno == EPERM);
    expectedInteger = 4;
    for (int i = 0; i < 3; i++) {
        int errors[] = { EINVAL, ENOTSUP, EBADF };
        returnedErrno = errors[i];
        assert(vpFcntl(123, expectedCommand, 4) == -1 && errno == errors[i]);
    }
    returnedResult = 0;
    returnedErrno = 0;
    assert(vpFcntl(123, expectedCommand, 4) == 0 && errno == 0);
    returnedResult = -1;
    returnedErrno = EPERM;
    expectedCommand = F_GETFD;
    assert(vpFcntl(123, expectedCommand) == -1 && errno == EPERM);
    expectedCommand = F_DUPFD;
    expectedInteger = 456;
    assert(vpFcntl(123, expectedCommand, 456) == -1 && errno == EPERM);
    expectedCommand = F_GETPATH;
    char path[1024];
    expectedPointer = path;
    assert(vpFcntl(123, expectedCommand, path) == -1 && errno == EPERM);
    puts("Cryptex staging forwarding, error policy and ephemeral DDI selection passed");
    return 0;
}

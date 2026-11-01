// libvphonefoldguard.m — keep SpringBoard alive under the foldable identity.
//
// The Duo product-id token (preboot-exp-devicetree_foldable_product_id) opens
// SpringBoard's fold layouts — and kills it on the single-display guest: the
// first CA transaction reaches
// -[CASecureIndicatorLayer _copyRenderLayer:layerFlags:commitFlags:], which
// raises CASecureIndicatorLayerInvalidName ("Invalid indicator name Camera";
// SpringBoard SIGABRT, com.apple.osanalytics
// SpringBoard-2026-10-25-103807/08, measured twice on iOS 27.1 24A94425).
//
// The validation was reversed end to end (2026-10-25, guest's own lowered
// cache + a live alias experiment; see Research/Guest/iphone_duo_bringup.md):
// _copyRenderLayer reads the layer's privacyIndicatorType and asks a
// validator that first consults a runtime registry — populated from the
// window server per display — and only falls back to a static name list
// (which contains "Camera", "Microphone", "MicrophoneAccessibility") when
// that registry pointer is nil. The virtual panel registers no secure
// indicator slots at all, so the registry is empty and every name is
// "invalid" — aliasing Camera to Microphone still raised, as Microphone.
// Filling the registry belongs to backboardd's CAWindowServerDisplay (the
// same missing display-topology family as the fold layout), so the client
// cannot fix it; the guard therefore catches the raise at the QuartzCore
// boundary and answers no layer copy. The commit proceeds without the
// secure indicator instead of taking the system app down, and the guard is
// inert on a guest without the foldable identity. Loaded by SystemHook into
// SpringBoard only.

#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#include <dlfcn.h>
#include <fcntl.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

static void vpFoldLog(NSString *format, ...) {
    va_list arguments;
    va_start(arguments, format);
    NSString *line = [[NSString alloc] initWithFormat:format arguments:arguments];
    va_end(arguments);
    if (!line)
        return;
    int fd = open("/var/mobile/Library/Caches/vphone-foldguard.log",
                  O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC, 0666);
    if (fd < 0)
        return;
    fchmod(fd, 0666);
    dprintf(fd, "pid=%d %s\n", getpid(), line.UTF8String);
    close(fd);
}

// QuartzCore returns an unmanaged CA::Render::Layer*, not an Objective-C
// object. An id return lets ARC retain that C++ pointer and PAC-fault in
// objc_msgSend on successful copies. Only forward pointer/integer GPR args.
static IMP vpOriginalCopyRender;

static const char *vpUnqualifiedType(const char *type) {
    while (*type && strchr("rnNoORV", *type)) type++;
    return type;
}

static BOOL vpCopyRenderABIIsSupported(Method method) {
    if (!method) return NO;
    NSMethodSignature *signature = [NSMethodSignature signatureWithObjCTypes:method_getTypeEncoding(method)];
    if (signature.numberOfArguments != 5 || signature.methodReturnLength != sizeof(void *) ||
        vpUnqualifiedType(signature.methodReturnType)[0] != '^') return NO;
    for (NSUInteger index = 2; index < 5; index++) {
        const char *type = vpUnqualifiedType([signature getArgumentTypeAtIndex:index]);
        if (!strchr("^QqIiLlSsCcB", type[0])) return NO;
        NSUInteger size = 0;
        NSGetSizeAndAlignment(type, &size, NULL);
        if (!size || size > sizeof(uintptr_t)) return NO;
    }
    return YES;
}

static void *vpGuardedCopyRender(id self, SEL selector, uintptr_t argument1, uintptr_t argument2, uintptr_t argument3) {
    @try {
        void *result = ((void *(*)(id, SEL, uintptr_t, uintptr_t, uintptr_t))vpOriginalCopyRender)(
            self, selector, argument1, argument2, argument3);
        static BOOL loggedNonNull = NO;
        if (result && !loggedNonNull) {
            loggedNonNull = YES;
            vpFoldLog(@"forwarded non-null unmanaged render layer without ARC ownership");
        }
        return result;
    } @catch (id exception) {
        static int swallowed = 0;
        int seen = swallowed++;
        if (seen < 5)
            vpFoldLog(@"swallowed secure-indicator exception #%d: %@ — %@", seen,
                      [(NSException *)exception name], [(NSException *)exception reason]);
        else if (seen == 5)
            vpFoldLog(@"further secure-indicator exceptions are not logged");
        return NULL;
    }
}

__attribute__((constructor)) static void vpInstallFoldGuard(void) {
    if (strcmp(getprogname(), "SpringBoard") != 0)
        return;
    dlopen("/System/Library/Frameworks/QuartzCore.framework/QuartzCore", RTLD_LAZY | RTLD_LOCAL);
    Class layer = objc_getClass("CASecureIndicatorLayer");
    Method copyRender = layer ? class_getInstanceMethod(
                                    layer, sel_registerName("_copyRenderLayer:layerFlags:commitFlags:"))
                              : NULL;
    if (!vpCopyRenderABIIsSupported(copyRender)) {
        vpFoldLog(@"CASecureIndicatorLayer pointer-copy ABI %@ — guard idle",
                  copyRender ? @(method_getTypeEncoding(copyRender)) : (layer ? @"missing" : @"class not found"));
        return;
    }
    vpOriginalCopyRender = method_getImplementation(copyRender);
    method_setImplementation(copyRender, (IMP)vpGuardedCopyRender);
    vpFoldLog(@"guard installed over _copyRenderLayer:layerFlags:commitFlags: ABI=%s (unmanaged pointer)", method_getTypeEncoding(copyRender));
}

#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#include <dlfcn.h>
#import "VPHomePodSiriSpeech.h"

void VPHomePodWelcomeInstall(void);
BOOL VPHomePodSoundGlowInstall(void);

// IOHIDUserDevice deliberately rejects reserved IOKit properties, including
// IOClass. MiniDisplay's HW3 path tests that property before reading MDHWVersion.
// Supply the identity only for our own virtual device; Apple's renderer and
// every frame submission remain untouched.
static id (*VPHomePodOriginalProperty)(id, SEL, NSString *, NSError **);
static void (*VPHomePodOriginalDeviceAdded)(id, SEL, CFTypeRef);
static BOOL (*VPHomePodOriginalSubmit)(id, SEL, id, NSError **);
static char VPHomePodLastRecovery;
#ifdef VP_HOMEPOD_DISPLAY_TESTING
extern CFTypeRef VPHomePodHIDProperty(CFTypeRef, CFStringRef);
extern int VPHomePodHIDOpen(CFTypeRef);
extern void VPHomePodHIDClose(CFTypeRef);
extern CFTypeRef VPHomePodCopyDisplay(void);
#else
static CFTypeRef VPHomePodHIDProperty(CFTypeRef device, CFStringRef key) {
    CFTypeRef (*get)(CFTypeRef, CFStringRef) = dlsym(RTLD_DEFAULT, "IOHIDDeviceGetProperty");
    return get ? get(device, key) : NULL;
}
static int VPHomePodHIDOpen(CFTypeRef device) {
    int (*open)(CFTypeRef, uint32_t) = dlsym(RTLD_DEFAULT, "IOHIDDeviceOpen");
    return open ? open(device, 0) : -1;
}
static void VPHomePodHIDClose(CFTypeRef device) {
    int (*close)(CFTypeRef, uint32_t) = dlsym(RTLD_DEFAULT, "IOHIDDeviceClose");
    if (close) close(device, 0);
}

// Enumerate immediately, without _findDevice's 30-second semaphore wait. A
// failed submission may happen while vphoned is still restarting.
static CFTypeRef VPHomePodCopyDisplay(void) {
    CFTypeRef (*create)(CFAllocatorRef, uint32_t) = dlsym(RTLD_DEFAULT, "IOHIDManagerCreate");
    void (*match)(CFTypeRef, CFDictionaryRef) = dlsym(RTLD_DEFAULT, "IOHIDManagerSetDeviceMatching");
    int (*open)(CFTypeRef, uint32_t) = dlsym(RTLD_DEFAULT, "IOHIDManagerOpen");
    CFSetRef (*copy)(CFTypeRef) = dlsym(RTLD_DEFAULT, "IOHIDManagerCopyDevices");
    int (*close)(CFTypeRef, uint32_t) = dlsym(RTLD_DEFAULT, "IOHIDManagerClose");
    if (!create || !match || !open || !copy || !close) return NULL;
    CFTypeRef manager = create(kCFAllocatorDefault, 0);
    if (!manager) return NULL;
    match(manager, (__bridge CFDictionaryRef)@{@"PhysicalDeviceUniqueID": @"vphone-homepod-mini-display"});
    CFTypeRef found = NULL;
    if (open(manager, 0) == 0) {
        CFSetRef devices = copy(manager);
        if (devices) {
            for (id device in (__bridge NSSet *)devices) {
                id identity = (__bridge id)VPHomePodHIDProperty((__bridge CFTypeRef)device, CFSTR("PhysicalDeviceUniqueID"));
                if ([identity isKindOfClass:NSString.class] && [identity isEqualToString:@"vphone-homepod-mini-display"]) {
                    found = CFRetain((__bridge CFTypeRef)device);
                    break;
                }
            }
            CFRelease(devices);
        }
        close(manager, 0);
    }
    CFRelease(manager);
    return found;
}
#endif

static bool VPHomePodIsVirtualDisplay(id identity) {
    return [identity isKindOfClass:NSString.class] && [identity isEqualToString:@"vphone-homepod-mini-display"];
}

static void VPHomePodDisplayDeviceAdded(id receiver, SEL selector, CFTypeRef device) {
    id identity = device ? (__bridge id)VPHomePodHIDProperty(device, CFSTR("PhysicalDeviceUniqueID")) : nil;
    if (!VPHomePodIsVirtualDisplay(identity)) {
        VPHomePodOriginalDeviceAdded(receiver, selector, device);
        return;
    }
    // deviceAdded: also tests IOClass directly in the registry. For our device
    // perform its normal retain/open/signal sequence using runtime ivars, never
    // firmware-specific object offsets. The original close/dealloc owns release.
    Ivar deviceIvar = class_getInstanceVariable([receiver class], "_device");
    Ivar semaphoreIvar = class_getInstanceVariable([receiver class], "_sema");
    if (!deviceIvar || !semaphoreIvar) return;
    uint8_t *storage = (uint8_t *)(__bridge void *)receiver + ivar_getOffset(deviceIvar);
    CFTypeRef previous = NULL;
    memcpy(&previous, storage, sizeof(previous));
    if (previous || VPHomePodHIDOpen(device) != 0) return;
    CFTypeRef retained = CFRetain(device);
    memcpy(storage, &retained, sizeof(retained));
    dispatch_semaphore_t semaphore = object_getIvar(receiver, semaphoreIvar);
    if (semaphore) dispatch_semaphore_signal(semaphore);
}

static id VPHomePodDisplayProperty(id receiver, SEL selector, NSString *key, NSError **error) {
    if ([key isEqualToString:@"IOClass"]) {
        id identity = VPHomePodOriginalProperty(receiver, selector, @"PhysicalDeviceUniqueID", NULL);
        if (VPHomePodIsVirtualDisplay(identity)) {
            return @"MiniDisplayDriver";
        }
    }
    return VPHomePodOriginalProperty(receiver, selector, key, error);
}

static BOOL VPHomePodSubmitFrame(id receiver, SEL selector, id frame, NSError **error) {
    NSError *submissionError = nil;
    if (VPHomePodOriginalSubmit(receiver, selector, frame, &submissionError)) return YES;
    Ivar ivar = class_getInstanceVariable([receiver class], "_device");
    uint8_t *storage = (uint8_t *)(__bridge void *)receiver + ivar_getOffset(ivar);
    CFTypeRef previous = NULL;
    memcpy(&previous, storage, sizeof(previous));
    id identity = previous ? (__bridge id)VPHomePodHIDProperty(previous, CFSTR("PhysicalDeviceUniqueID")) : nil;
    if (VPHomePodIsVirtualDisplay(identity)) {
        // SoundBoard retains its HID interface across a daemon restart. Only
        // replace our failed virtual handle, and leave frame generation alone.
        NSTimeInterval now = NSProcessInfo.processInfo.systemUptime;
        NSNumber *last = objc_getAssociatedObject(receiver, &VPHomePodLastRecovery);
        if (!last || now - last.doubleValue >= 1) {
            objc_setAssociatedObject(receiver, &VPHomePodLastRecovery, @(now), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            CFTypeRef replacement = VPHomePodCopyDisplay();
            if (replacement && replacement != previous && VPHomePodHIDOpen(replacement) == 0) {
                VPHomePodHIDClose(previous);
                memcpy(storage, &replacement, sizeof(replacement));
                CFRelease(previous);
                submissionError = nil;
                BOOL result = VPHomePodOriginalSubmit(receiver, selector, frame, &submissionError);
                if (!result && error) *error = submissionError;
                return result;
            }
            if (replacement) CFRelease(replacement);
        }
    }
    if (error) *error = submissionError;
    return NO;
}

bool VPHomePodInstallDisplayIdentity(void) {
    static bool installed;
    if (installed) return true;
    Class interface = NSClassFromString(@"MDInterfaceHID");
    Method method = class_getInstanceMethod(interface, NSSelectorFromString(@"_getPropertyForKey:error:"));
    Method added = class_getInstanceMethod(interface, NSSelectorFromString(@"deviceAdded:"));
    Method submit = class_getInstanceMethod(interface, NSSelectorFromString(@"submitFrame:error:"));
    // Fail visibly on a changed framework instead of guessing a method ABI.
    if (!method || method_getNumberOfArguments(method) != 4 || !added || method_getNumberOfArguments(added) != 3 ||
        !submit || method_getNumberOfArguments(submit) != 4 ||
        !class_getInstanceVariable(interface, "_device") || !class_getInstanceVariable(interface, "_sema")) return false;
    char returnType[16] = {0};
    method_getReturnType(method, returnType, sizeof(returnType));
    if (strcmp(returnType, @encode(id)) != 0) return false;
    method_getReturnType(added, returnType, sizeof(returnType));
    if (strcmp(returnType, @encode(void)) != 0) return false;
    char argumentType[128] = {0};
    method_getArgumentType(added, 2, argumentType, sizeof(argumentType));
    if (argumentType[0] != '^') return false;
    method_getReturnType(submit, returnType, sizeof(returnType));
    if (strcmp(returnType, @encode(BOOL)) != 0) return false;
    VPHomePodOriginalProperty = (void *)method_setImplementation(method, (IMP)VPHomePodDisplayProperty);
    VPHomePodOriginalDeviceAdded = (void *)method_setImplementation(added, (IMP)VPHomePodDisplayDeviceAdded);
    VPHomePodOriginalSubmit = (void *)method_setImplementation(submit, (IMP)VPHomePodSubmitFrame);
    installed = true;
    return true;
}

#ifndef VP_HOMEPOD_DISPLAY_TESTING
__attribute__((constructor)) static void VPHomePodDisplayInitialize(void) {
    @autoreleasepool {
        if ([NSProcessInfo.processInfo.processName isEqualToString:@"NowPlayingCap"]) {
            VPHomePodSoundGlowInstall();
            return;
        }
        // The executable load command limits this library to SoundBoard. dlopen ensures
        // its MiniDisplay class is registered before we install the adapter.
        void *framework = dlopen("/System/Library/PrivateFrameworks/MiniDisplay.framework/MiniDisplay", RTLD_NOW);
        if (!framework || !VPHomePodInstallDisplayIdentity()) {
            NSLog(@"vphone HomePod display: MiniDisplay identity adapter unavailable");
        } else {
            NSLog(@"vphone HomePod display: virtual MiniDisplay identity adapter ready");
            if (VPHomePodSiriSpeechInstall()) {
                NSLog(@"vphone HomePod Siri speech: isolated playback session adapter ready");
                VPHomePodWelcomeInstall();
            }
        }
    }
}
#endif

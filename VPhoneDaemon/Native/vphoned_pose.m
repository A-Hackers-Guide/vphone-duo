/*
 * vphoned_pose — SpringBoard's device pose, through its test automation.
 *
 * A VM has no hinge sensor CoreMotion will open, so SpringBoard's pose stays
 * at its default and it draws on the cover display only. SpringBoardServices'
 * SBSTestAutomationService lets a test tool override the pose instead:
 * `setDevicePoseOverride:` takes {orientation; device orientation; hinge
 * state; tabletop}, and SpringBoard's "Test Automation" pose transformer
 * turns the hinge state into a CoreMotion magic pose and a canned hinge
 * angle. It needs `com.apple.springboard.testautomation`, the test tools'
 * entitlement. Nothing about what iOS believes it runs on changes.
 *
 * The class is resolved at run time, so a base without it still starts and
 * the call reports nil or false instead.
 */

#import "Include/VphonedNative.h"

#include <dlfcn.h>
#include <objc/message.h>

typedef struct {
    long long orientation;
    int deviceOrientation;
    int hingeState;
    int tabletop;
} VPhoneDevicePose;

static id VPhonePoseService(void) {
    static Class service;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        dlopen("/System/Library/PrivateFrameworks/SpringBoardServices.framework/SpringBoardServices", RTLD_NOW);
        service = NSClassFromString(@"SBSTestAutomationService");
    });
    if (!service) return nil;
    id instance = [[service alloc] init];
    if (![instance respondsToSelector:NSSelectorFromString(@"setDevicePoseOverride:")] ||
        ![instance respondsToSelector:NSSelectorFromString(@"getDevicePose")])
        return nil;
    return instance;
}

static void VPhonePoseRelease(id service) {
    SEL invalidate = NSSelectorFromString(@"invalidate");
    if ([service respondsToSelector:invalidate]) ((void (*)(id, SEL))objc_msgSend)(service, invalidate);
}

static NSDictionary *VPhonePoseEncode(VPhoneDevicePose pose) {
    return @{
        @"orientation": @(pose.orientation),
        @"device_orientation": @(pose.deviceOrientation),
        @"hinge_state": @(pose.hingeState),
        @"tabletop": @(pose.tabletop),
    };
}

NSDictionary *vp_pose_get(void) {
    id service = VPhonePoseService();
    if (!service) return nil;
    VPhoneDevicePose pose =
        ((VPhoneDevicePose(*)(id, SEL))objc_msgSend)(service, NSSelectorFromString(@"getDevicePose"));
    VPhonePoseRelease(service);
    return VPhonePoseEncode(pose);
}

BOOL vp_pose_set(long long orientation, int deviceOrientation, int hingeState, int tabletop) {
    id service = VPhonePoseService();
    if (!service) return NO;
    VPhoneDevicePose pose = {orientation, deviceOrientation, hingeState, tabletop};
    ((void (*)(id, SEL, VPhoneDevicePose))objc_msgSend)(service, NSSelectorFromString(@"setDevicePoseOverride:"),
                                                        pose);
    VPhonePoseRelease(service);
    return YES;
}

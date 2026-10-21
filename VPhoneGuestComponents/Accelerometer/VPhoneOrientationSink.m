#import "VPhoneOrientationSink.h"
#include <math.h>
#include <objc/message.h>
#include <objc/runtime.h>

@interface VPhoneDeviceOrientationSink : NSObject
@property (nonatomic, weak) id manager;
@property (nonatomic, strong) dispatch_queue_t queue;
@property (nonatomic, strong) dispatch_queue_t statusQueue;
@property (nonatomic, copy) dispatch_block_t statusChanged;
@property (nonatomic) NSInteger orientation;
@property (nonatomic) NSInteger deliveredOrientation;
@property (nonatomic) uint64_t deliveries;
@property (nonatomic, copy) NSString *error;
@end
@implementation VPhoneDeviceOrientationSink
@end

static VPhoneDeviceOrientationSink *vpOrientationSink;
static void (*vpOriginalServicesMatched)(id, SEL, id, id);
static void (*vpOriginalSetupPipeline)(id, SEL, id);

static void vpOrientationDeliver(void) {
    VPhoneDeviceOrientationSink *sink = vpOrientationSink;
    id manager;
    dispatch_queue_t queue;
    @synchronized (sink) { manager = sink.manager; queue = sink.queue; }
    if (!manager || !queue)
        return;
    dispatch_async(queue, ^{
        NSInteger orientation;
        @synchronized (sink) {
            orientation = sink.orientation;
            if (manager != sink.manager || orientation == sink.deliveredOrientation)
                return;
        }
        ((void (*)(id, SEL, NSInteger))objc_msgSend)(manager,
            sel_registerName("_queue_postUpdatedRawAccelerometerDeviceOrientation:"), orientation);
        dispatch_queue_t statusQueue;
        dispatch_block_t changedHandler;
        @synchronized (sink) {
            sink.deliveredOrientation = orientation;
            sink.deliveries++;
            statusQueue = sink.statusQueue;
            changedHandler = sink.statusChanged;
        }
        if (statusQueue && changedHandler)
            dispatch_async(statusQueue, changedHandler);
    });
}

static void vpOrientationServicesMatched(id manager, SEL selector, id matcher, id services) {
    vpOriginalServicesMatched(manager, selector, matcher, services);
    Ivar queueIvar = class_getInstanceVariable(object_getClass(manager), "_queue");
    dispatch_queue_t queue = queueIvar ? object_getIvar(manager, queueIvar) : nil;
    if (!queue)
        return;
    @synchronized (vpOrientationSink) {
        if (manager != vpOrientationSink.manager)
            vpOrientationSink.deliveredOrientation = 0;
        vpOrientationSink.manager = manager;
        vpOrientationSink.queue = queue;
        vpOrientationSink.error = nil;
    }
    vpOrientationDeliver();
}

void VPhoneOrientationSinkInstall(dispatch_queue_t statusQueue, dispatch_block_t statusChanged) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        vpOrientationSink = [VPhoneDeviceOrientationSink new];
        vpOrientationSink.orientation = 1;
        vpOrientationSink.statusQueue = statusQueue;
        vpOrientationSink.statusChanged = statusChanged;
        vpOrientationSink.error = @"Waiting for the built-in accelerometer match";
        Class cls = NSClassFromString(@"BKOrientationManager");
        Method match = class_getInstanceMethod(cls, sel_registerName("matcher:servicesDidMatch:"));
        Method post = class_getInstanceMethod(cls,
            sel_registerName("_queue_postUpdatedRawAccelerometerDeviceOrientation:"));
        if (!match || !post || !class_getInstanceVariable(cls, "_queue") ||
            method_getNumberOfArguments(match) != 4 || method_getNumberOfArguments(post) != 3) {
            vpOrientationSink.error = @"Native backboardd device-orientation sink unavailable";
            return;
        }
        vpOriginalServicesMatched = (void (*)(id, SEL, id, id))method_setImplementation(
            match, (IMP)vpOrientationServicesMatched);
    });
}

void VPhoneOrientationSinkPublish(id<VPhoneAccelerometerHIDEvent> event) {
    // A dead band excludes flat/ambiguous samples. This BKS sink uses 4 for
    // the 90-degree interface and 3 for 270, unlike UIDevice's landscape
    // numbering. Confirmed with gravity-only guest readback (without AX).
    double x = event.accelerometerX, y = event.accelerometerY, z = event.accelerometerZ;
    NSInteger orientation = 0;
    if (fabs(z) < 0.5) {
        if (fabs(x) > 0.75 && fabs(y) < 0.5)
            orientation = x < 0 ? 4 : 3;
        else if (fabs(y) > 0.75 && fabs(x) < 0.5)
            orientation = y < 0 ? 1 : 2;
    }
    if (!orientation || !vpOrientationSink)
        return;
    @synchronized (vpOrientationSink) { vpOrientationSink.orientation = orientation; }
    vpOrientationDeliver();
}

NSDictionary *VPhoneOrientationSinkStatus(void) {
    VPhoneDeviceOrientationSink *sink = vpOrientationSink;
    if (!sink)
        return @{@"ready": @NO, @"error": @"Orientation bridge not installed"};
    @synchronized (sink) {
        return @{@"ready": @(sink.manager != nil && sink.queue != nil),
            @"device_orientation": @(sink.deliveredOrientation), @"deliveries": @(sink.deliveries),
            @"error": sink.error ?: @""};
    }
}

// MARK: - SpringBoard's backlight seed

static void vpOrientationSetupPipeline(id manager, SEL selector, id arbiter) {
    vpOriginalSetupPipeline(manager, selector, arbiter);
    Class cls = NSClassFromString(@"SBBacklightController");
    SEL shared = sel_registerName("sharedInstanceIfExists");
    if (![cls respondsToSelector:shared])
        return;
    id controller = ((id (*)(id, SEL))objc_msgSend)(cls, shared);
    SEL screenIsOn = sel_registerName("screenIsOn");
    if (![controller respondsToSelector:screenIsOn])
        return;
    BOOL on = ((BOOL (*)(id, SEL))objc_msgSend)(controller, screenIsOn);
    [manager setValue:@(on) forKey:@"_backlightIsOn"];
    ((void (*)(id, SEL))objc_msgSend)(manager, sel_registerName("_updateOrientationEventsEnabledState"));
    ((void (*)(id, SEL, BOOL))objc_msgSend)(manager,
        sel_registerName("_updateOrientationInputsDeferralAnimated:"), NO);
    NSLog(@"[vphone-accelerometer] Recomputed orientation gates after backlight seed: %d", on);
}

void VPhoneOrientationGateInstall(void) {
    Class cls = NSClassFromString(@"SBTraitsEmbeddedDisplayPipelineManager");
    Method method = class_getInstanceMethod(cls, sel_registerName("setupDefaultPipelineForArbiter:"));
    if (!method || method_getNumberOfArguments(method) != 3 ||
        !class_getInstanceVariable(cls, "_backlightIsOn") ||
        ![cls instancesRespondToSelector:sel_registerName("_updateOrientationEventsEnabledState")] ||
        ![cls instancesRespondToSelector:sel_registerName("_updateOrientationInputsDeferralAnimated:")]) {
        NSLog(@"[vphone-accelerometer] SpringBoard orientation gate API unavailable");
        return;
    }
    vpOriginalSetupPipeline = (void (*)(id, SEL, id))method_setImplementation(method, (IMP)vpOrientationSetupPipeline);
}

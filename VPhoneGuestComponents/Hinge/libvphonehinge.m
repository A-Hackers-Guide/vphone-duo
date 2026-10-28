#import "../Gyroscope/VPhoneGyroscopeHID.h"
#import "VPhoneHingeState.h"
#include <dlfcn.h>
#include <objc/message.h>
#include <mach/mach_time.h>
#include <notify.h>
#include <unistd.h>

// MARK: - Virtual hinge angle sensor in backboardd
//
// The iPhone Duo's hinge angle reaches iOS from the AOP as HID events of type
// kIOHIDEventTypeHingeAngle on usage page 0xFF0C (kHIDPage_AppleVendorMotion),
// usage 0x21. CoreMotion's CLAngleNotifier opens exactly that pair (the 8-byte
// constant its openHIDDriverInterfaceIfNeeded loads in 24B91020), asserts the
// event type, and feeds SpringBoard's SBFDevicePoseProvider, which decides
// between the outer and inner display. The VM has no AOP, so this service
// stands in for it, publishing the host's hinge slider unchanged.

typedef CFTypeRef VPHingeEventRef;
typedef VPHingeEventRef (*VPHingeEventCreate)(CFAllocatorRef, uint64_t, double, double, double, uint32_t);

@interface VPhoneHingeProvider : NSObject
@property (nonatomic, strong) dispatch_queue_t queue;
@property (nonatomic, strong) dispatch_source_t timer;
@property (nonatomic, strong) id<VPhoneGyroscopeHIDService> service;
@property (nonatomic, strong) NSMutableDictionary *properties;
@property (nonatomic) VPHingeEventCreate create;
@property (nonatomic) VPhoneHingeState state;
@property (nonatomic) BOOL enumerated;
@property (nonatomic) BOOL cancelling;
@property (nonatomic) uint64_t interval;
@property (nonatomic) uint64_t dispatched;
@property (nonatomic) uint64_t failures;
@property (nonatomic) int notificationToken;
@property (nonatomic, copy) NSString *lastError;
- (void)start;
@end

@implementation VPhoneHingeProvider

- (void)publishStatus {
    NSDictionary *status = @{
        @"enumerated": @(self.enumerated), @"service_id": @(self.service.serviceID),
        @"pid": @(getpid()), @"updated_at": @([NSDate date].timeIntervalSince1970),
        @"report_interval_us": @(self.interval), @"dispatched": @(self.dispatched),
        @"dispatch_failures": @(self.failures), @"error": self.lastError ?: @"",
        @"configuration": VPhoneHingeEncode(self.state),
    };
    CFPreferencesSetValue(CFSTR(VP_HINGE_STATUS), (__bridge CFDictionaryRef)status,
                          CFSTR(VP_HINGE_DOMAIN), CFSTR("mobile"), kCFPreferencesAnyHost);
    CFPreferencesSynchronize(CFSTR(VP_HINGE_DOMAIN), CFSTR("mobile"), kCFPreferencesAnyHost);
}

- (id)sample {
    VPhoneHingeState state = self.state;
    // Disabled reads as a phone lying open flat, the state Duo firmware
    // reports before the hinge is first moved.
    double angle = state.enabled ? state.angle : VP_HINGE_ANGLE_MAX;
    double velocity = state.enabled ? state.velocity : 0;
    VPHingeEventRef event = self.create(kCFAllocatorDefault, mach_absolute_time(), angle, angle, velocity, 0);
    if (!event)
        return nil;
    id object = CFBridgingRelease(event);
    if ([object respondsToSelector:@selector(setHingeAngleState:)])
        ((void (*)(id, SEL, uint32_t))objc_msgSend)(object, @selector(setHingeAngleState:), (uint32_t)state.state);
    return object;
}

- (void)dispatchSample {
    @autoreleasepool {
        id event = self.enumerated ? [self sample] : nil;
        if (event && [self.service dispatchEvent:event]) {
            self.dispatched++;
        } else if (self.enumerated) {
            self.failures++;
            self.lastError = @"HID event dispatch failed";
        }
    }
}

- (void)readConfiguration {
    CFPreferencesSynchronize(CFSTR(VP_HINGE_DOMAIN), CFSTR("mobile"), kCFPreferencesAnyHost);
    id value = CFBridgingRelease(CFPreferencesCopyValue(CFSTR(VP_HINGE_CONFIGURATION),
                                  CFSTR(VP_HINGE_DOMAIN), CFSTR("mobile"), kCFPreferencesAnyHost));
    VPhoneHingeState state;
    VPhoneHingeDecode(value, &state);
    self.state = state;
    // A hinge change is an event, not a sample: deliver it now so the pose
    // provider sees every slider position, then keep the client's cadence.
    [self dispatchSample];
    [self publishStatus];
}

- (void)updateTimer {
    uint64_t period = self.enumerated && self.interval ? self.interval * NSEC_PER_USEC : DISPATCH_TIME_FOREVER;
    dispatch_source_set_timer(self.timer, period == DISPATCH_TIME_FOREVER ? DISPATCH_TIME_FOREVER : DISPATCH_TIME_NOW,
                              period, NSEC_PER_MSEC);
}

- (void)createService {
    self.enumerated = NO;
    self.cancelling = NO;
    self.interval = 0;
    self.properties[@"ReportInterval"] = @0;
    self.service = (id<VPhoneGyroscopeHIDService>)[NSClassFromString(@"HIDVirtualEventService") new];
    if (!self.service) {
        self.lastError = @"HIDVirtualEventService creation failed";
        [self publishStatus];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC), self.queue, ^{ [self createService]; });
        return;
    }
    self.service.delegate = self;
    [self.service setDispatchQueue:self.queue];
    __weak VPhoneHingeProvider *weakSelf = self;
    [self.service setCancelHandler:^{
        VPhoneHingeProvider *provider = weakSelf;
        if (!provider)
            return;
        provider.service = nil;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC), provider.queue,
                       ^{ [provider createService]; });
    }];
    [self.service activate];
}

- (void)start {
    void *hid = dlopen("/System/Library/PrivateFrameworks/HID.framework/HID", RTLD_NOW | RTLD_LOCAL);
    self.create = (VPHingeEventCreate)dlsym(RTLD_DEFAULT, "IOHIDEventCreateHingeAngleEvent");
    Class serviceClass = NSClassFromString(@"HIDVirtualEventService");
    if (!hid || !self.create || !serviceClass || ![serviceClass instancesRespondToSelector:@selector(dispatchEvent:)]) {
        self.lastError = @"Required HID hinge-angle API unavailable";
        NSLog(@"[vphone-hinge] %@", self.lastError);
        [self publishStatus];
        return;
    }
    self.properties = [@{
        @"PrimaryUsagePage": @0xff0c, @"PrimaryUsage": @0x21,
        @"DeviceUsagePairs": @[@{@"DeviceUsagePage": @0xff0c, @"DeviceUsage": @0x21}],
        @"Product": @"VPhone Hinge Angle", @"Manufacturer": @"vphone",
        @"Transport": @"Virtual", @"Built-In": @YES,
        @"ReportInterval": @0, @"BatchInterval": @0,
        @"HIDDefaultSensorControlOptions": @7, @"SensorPropertySupported": @3,
    } mutableCopy];
    self.timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, self.queue);
    dispatch_source_set_event_handler(self.timer, ^{ [self dispatchSample]; });
    [self updateTimer];
    dispatch_resume(self.timer);
    int status = notify_register_dispatch(VP_HINGE_NOTIFICATION, &_notificationToken, self.queue,
                                          ^(int token) { [self readConfiguration]; });
    if (status != NOTIFY_STATUS_OK) {
        self.lastError = @"Hinge configuration notification registration failed";
        [self publishStatus];
        return;
    }
    [self readConfiguration];
    [self createService];
}

// MARK: - HIDVirtualEventServiceDelegate selectors

- (id)propertyForKey:(NSString *)key forService:(id)service {
    return self.properties[key];
}

- (BOOL)setProperty:(id)value forKey:(NSString *)key forService:(id)service {
    if ([key isEqualToString:@"ReportInterval"]) {
        self.interval = VPhoneHingeInterval(value);
        self.properties[key] = @(self.interval);
        [self updateTimer];
        [self publishStatus];
        return YES;
    }
    return [key isEqualToString:@"BatchInterval"];
}

- (id)copyEventMatching:(NSDictionary *)matching forService:(id)service {
    NSNumber *type = matching[@"EventType"];
    return self.enumerated && (!type || type.unsignedIntValue == VP_HINGE_EVENT_TYPE) ? [self sample] : nil;
}

- (BOOL)setOutputEvent:(id)event forService:(id)service {
    return NO;
}

- (void)notification:(NSInteger)type withProperty:(NSDictionary *)property forService:(id)service {
    if (service != self.service)
        return;
    if (type == 10) { // HIDVirtualServiceNotificationTypeEnumerated
        self.enumerated = YES;
        self.lastError = nil;
        NSLog(@"[vphone-hinge] HID service enumerated: %llu", self.service.serviceID);
        [self dispatchSample];
    } else if (type == 11 && !self.cancelling) { // Terminated or reset
        self.enumerated = NO;
        self.cancelling = YES;
        self.lastError = @"HID service terminated; waiting to register again";
        [self.service cancel];
    }
    [self updateTimer];
    [self publishStatus];
}
@end

// Only a guest whose userland expects a hinge gets the sensor.
static BOOL VPhoneHingeGuestHasHinge(void) {
    void *gestalt = dlopen("/usr/lib/libMobileGestalt.dylib", RTLD_NOW | RTLD_LOCAL);
    CFStringRef (*copyAnswer)(CFStringRef) = gestalt ? dlsym(gestalt, "MGCopyAnswer") : NULL;
    NSString *product = copyAnswer ? CFBridgingRelease(copyAnswer(CFSTR("ProductType"))) : nil;
    return [product isKindOfClass:NSString.class] && [product isEqualToString:@"iPhone19,4"];
}

__attribute__((constructor)) static void VPhoneHingeStart(void) {
    if (strcmp(getprogname(), "backboardd") != 0)
        return;
    static VPhoneHingeProvider *provider;
    provider = [VPhoneHingeProvider new];
    provider.queue = dispatch_queue_create("com.vphone.motion.hinge", DISPATCH_QUEUE_SERIAL);
    dispatch_async(provider.queue, ^{
        if (VPhoneHingeGuestHasHinge())
            [provider start];
    });
}

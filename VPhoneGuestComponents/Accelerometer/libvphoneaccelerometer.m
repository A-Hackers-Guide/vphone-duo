#import "VPhoneAccelerometerHID.h"
#import "VPhoneAccelerometerState.h"
#import "VPhoneOrientationSink.h"
#include <dlfcn.h>
#include <mach/mach_time.h>
#include <notify.h>
#include <unistd.h>

// MARK: - HID provider in backboardd

@interface VPhoneAccelerometerProvider : NSObject
@property (nonatomic, strong) dispatch_queue_t queue;
@property (nonatomic, strong) dispatch_source_t timer;
@property (nonatomic, strong) dispatch_source_t heartbeat;
@property (nonatomic, strong) id<VPhoneAccelerometerHIDService> service;
@property (nonatomic) Class<VPhoneAccelerometerHIDEvent> eventClass;
@property (nonatomic, strong) NSMutableDictionary *properties;
@property (nonatomic) int degrees;
@property (nonatomic) BOOL enumerated;
@property (nonatomic) BOOL cancelling;
@property (nonatomic) uint32_t sequence;
@property (nonatomic) uint64_t interval;
@property (nonatomic) uint64_t dispatched;
@property (nonatomic) uint64_t failures;
@property (nonatomic) int notificationToken;
@property (nonatomic, copy) NSString *lastError;
- (void)start;
- (void)dispatchSample;
@end

@implementation VPhoneAccelerometerProvider

- (void)publishStatus {
    NSDictionary *status = @{
        @"enumerated": @(self.enumerated), @"service_id": @(self.service.serviceID),
        @"pid": @(getpid()), @"updated_at": @([NSDate date].timeIntervalSince1970),
        @"report_interval_us": @(self.interval), @"dispatched": @(self.dispatched),
        @"dispatch_failures": @(self.failures), @"error": self.lastError ?: @"",
        @"configuration": @{@"degrees": @(self.degrees)},
        @"orientation_sink": VPhoneOrientationSinkStatus(),
    };
    CFPreferencesSetValue(CFSTR(VP_ACCEL_STATUS), (__bridge CFDictionaryRef)status,
                          CFSTR(VP_ACCEL_DOMAIN), CFSTR("mobile"), kCFPreferencesAnyHost);
    CFPreferencesSynchronize(CFSTR(VP_ACCEL_DOMAIN), CFSTR("mobile"), kCFPreferencesAnyHost);
}

- (void)readConfiguration {
    CFPreferencesSynchronize(CFSTR(VP_ACCEL_DOMAIN), CFSTR("mobile"), kCFPreferencesAnyHost);
    id value = CFBridgingRelease(CFPreferencesCopyValue(CFSTR(VP_ACCEL_CONFIGURATION),
                                  CFSTR(VP_ACCEL_DOMAIN), CFSTR("mobile"), kCFPreferencesAnyHost));
    int degrees;
    VPhoneAccelerometerDecode(value, &degrees);
    self.degrees = degrees;
    if (self.enumerated)
        [self dispatchSample];
    [self publishStatus];
}

- (void)updateTimer {
    uint64_t period = self.enumerated && self.interval ? self.interval * NSEC_PER_USEC : DISPATCH_TIME_FOREVER;
    dispatch_source_set_timer(self.timer, period == DISPATCH_TIME_FOREVER ? DISPATCH_TIME_FOREVER : DISPATCH_TIME_NOW,
                              period, NSEC_PER_MSEC);
    // The status is republished every two seconds only while samples flow,
    // to keep its dispatch counts current. Otherwise it changes only at the
    // transitions, which publish it themselves, and vphoned judges the
    // provider by its pid. An unconditional heartbeat had backboardd rewrite
    // the preferences domain through cfprefsd every two seconds for the
    // guest's whole life.
    if (self.heartbeat) {
        BOOL flowing = period != DISPATCH_TIME_FOREVER;
        dispatch_source_set_timer(self.heartbeat,
                                  flowing ? dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC) : DISPATCH_TIME_FOREVER,
                                  2 * NSEC_PER_SEC, 100 * NSEC_PER_MSEC);
    }
}

- (id)sample {
    VPhoneGravity gravity = VPhoneAccelerometerGravity(self.degrees);
    id event = [self.eventClass accelerometerEvent:mach_absolute_time()
                                             x:gravity.x y:gravity.y z:gravity.z options:0];
    if (event)
        [(id<VPhoneAccelerometerHIDEvent>)event setAccelerometerSequence:self.sequence++];
    return event;
}

- (void)createService {
    self.enumerated = NO;
    self.cancelling = NO;
    self.interval = 0;
    self.properties[@"ReportInterval"] = @0;
    self.service = (id<VPhoneAccelerometerHIDService>)[NSClassFromString(@"HIDVirtualEventService") new];
    if (!self.service) {
        self.lastError = @"HIDVirtualEventService creation failed";
        [self publishStatus];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC), self.queue, ^{ [self createService]; });
        return;
    }
    self.service.delegate = self;
    [self.service setDispatchQueue:self.queue];
    __weak VPhoneAccelerometerProvider *weakSelf = self;
    [self.service setCancelHandler:^{
        VPhoneAccelerometerProvider *provider = weakSelf;
        if (!provider)
            return;
        provider.service = nil;
        // A reset invalidates the old service. Cancel completely before
        // releasing it, then register a new one with the restarted HID server.
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC), provider.queue,
                       ^{ [provider createService]; });
    }];
    [self.service activate];
}

- (void)dispatchSample {
    id event = [self sample];
    if (event && [self.service dispatchEvent:event]) {
        self.dispatched++;
        self.lastError = nil;
    } else {
        self.failures++;
        self.lastError = @"HID event dispatch failed";
    }
    if (event)
        VPhoneOrientationSinkPublish(event);
}

- (void)start {
    void *hid = dlopen("/System/Library/PrivateFrameworks/HID.framework/HID", RTLD_NOW | RTLD_LOCAL);
    self.eventClass = (Class<VPhoneAccelerometerHIDEvent>)NSClassFromString(@"HIDEvent");
    Class serviceClass = NSClassFromString(@"HIDVirtualEventService");
    if (!hid || !serviceClass ||
        ![self.eventClass respondsToSelector:@selector(accelerometerEvent:x:y:z:options:)] ||
        ![(Class)self.eventClass instancesRespondToSelector:@selector(setAccelerometerSequence:)] ||
        ![serviceClass instancesRespondToSelector:@selector(dispatchEvent:)]) {
        self.lastError = @"Required HID virtual-service API unavailable";
        NSLog(@"[vphone-accelerometer] %@", self.lastError);
        [self publishStatus];
        return;
    }
    self.properties = [@{
        @"PrimaryUsagePage": @0xff00, @"PrimaryUsage": @3,
        @"DeviceUsagePairs": @[@{@"DeviceUsagePage": @0xff00, @"DeviceUsage": @3}],
        @"Product": @"VPhone Gravity Accelerometer", @"Manufacturer": @"vphone",
        @"Transport": @"Virtual", @"Built-In": @YES, @"IMULocationID": @0,
        @"ReportInterval": @0, @"BatchInterval": @0,
        // Aggregate subscriptions before forwarding the requested interval to
        // this delegate, so one client's stop cannot stop other subscribers.
        @"HIDDefaultSensorControlOptions": @7, @"SensorPropertySupported": @3,
    } mutableCopy];
    [self readConfiguration];
    int status = notify_register_dispatch(VP_ACCEL_NOTIFICATION, &_notificationToken, self.queue,
                                          ^(int token) { [self readConfiguration]; });
    if (status != NOTIFY_STATUS_OK) {
        self.lastError = @"Accelerometer configuration notification registration failed";
        [self publishStatus];
        return;
    }
    self.timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, self.queue);
    dispatch_source_set_event_handler(self.timer, ^{
        @autoreleasepool {
            [self dispatchSample];
        }
    });
    self.heartbeat = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, self.queue);
    dispatch_source_set_event_handler(self.heartbeat, ^{ [self publishStatus]; });
    [self updateTimer];
    dispatch_resume(self.timer);
    dispatch_resume(self.heartbeat);
    [self createService];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC), self.queue, ^{
        VPhoneOrientationSinkRetry();
        [self publishStatus];
    });
}

// MARK: - HIDVirtualEventServiceDelegate selectors

- (id)propertyForKey:(NSString *)key forService:(id)service {
    return self.properties[key];
}

- (BOOL)setProperty:(id)value forKey:(NSString *)key forService:(id)service {
    if (service != self.service)
        return NO;
    if ([key isEqualToString:@"ReportInterval"]) {
        self.interval = VPhoneAccelerometerInterval(value);
        self.properties[key] = @(self.interval);
        [self updateTimer];
        [self publishStatus];
        return YES;
    }
    if ([key isEqualToString:@"BatchInterval"])
        return YES; // No FIFO: samples are delivered as they are made.
    return NO;
}

- (id)copyEventMatching:(NSDictionary *)matching forService:(id)service {
    NSNumber *type = matching[@"EventType"];
    return service == self.service && self.enumerated && (!type || type.unsignedIntValue == 0x0d) ? [self sample] : nil;
}

- (BOOL)setOutputEvent:(id)event forService:(id)service {
    return NO;
}

- (void)notification:(NSInteger)type withProperty:(NSDictionary *)property forService:(id)service {
    if (service != self.service)
        return;
    if (type == 10) { // HIDVirtualServiceNotificationTypeEnumerated
        VPhoneOrientationSinkRetry();
        self.enumerated = YES;
        self.lastError = nil;
        NSLog(@"[vphone-accelerometer] HID service enumerated: %llu", self.service.serviceID);
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

__attribute__((constructor)) static void VPhoneAccelerometerStart(void) {
    if (strcmp(getprogname(), "SpringBoard") == 0) {
        VPhoneOrientationGateInstall();
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
            VPhoneOrientationGateInstall();
        });
        return;
    }
    // Only backboardd creates the HID service; SpringBoard installs the seed
    // repair above. Starting asynchronously avoids calling the HID server
    // while its daemon is still running image constructors.
    if (strcmp(getprogname(), "backboardd") != 0)
        return;
    static VPhoneAccelerometerProvider *provider;
    provider = [VPhoneAccelerometerProvider new];
    provider.queue = dispatch_queue_create("com.vphone.motion.accelerometer", DISPATCH_QUEUE_SERIAL);
    VPhoneOrientationSinkInstall(provider.queue, ^{ [provider publishStatus]; });
    dispatch_async(provider.queue, ^{ [provider start]; });
}

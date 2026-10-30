#import "../Gyroscope/VPhoneGyroscopeHID.h"
#import "VPhonePanelTouch.h"
#include <dlfcn.h>
#include <objc/message.h>
#include <unistd.h>

// MARK: - The touchscreen of an identified panel, in backboardd
//
// backboardd routes a touch to its sender's display: BKIOHIDService reads the
// HID service's `displayUUID` property once, when the service appears. An
// iPhone Duo's touchscreens name their panels (`service-display` in the
// device tree); the Simulator gives its touch service a display the same way
// (-[BKIOHIDService initForSimulatorWithDisplayUUID:]). A guest whose display
// the host gave an identifier (an iPhone Duo booted on its inner panel) has a
// touchscreen that names none, so its touches reach no display. This service
// stands in for that panel's touchscreen: a built-in, display-integrated
// digitizer carrying the display's identifier. It sends nothing itself;
// vphoned dispatches its touch events under this service's ID.

@interface VPhonePanelTouchProvider : NSObject
@property (nonatomic, strong) dispatch_queue_t queue;
@property (nonatomic, strong) id<VPhoneGyroscopeHIDService> service;
@property (nonatomic, copy) NSDictionary *properties;
@property (nonatomic) BOOL enumerated;
@property (nonatomic) BOOL cancelling;
@property (nonatomic) int attempts;
@property (nonatomic, copy) NSString *displayUUID;
@property (nonatomic, copy) NSString *lastError;
- (void)start;
@end

@implementation VPhonePanelTouchProvider

- (void)publishStatus {
    NSDictionary *status = @{
        @"enumerated": @(self.enumerated), @"service_id": @(self.service.serviceID),
        @"display_uuid": self.displayUUID ?: @"", @"pid": @(getpid()),
        @"updated_at": @([NSDate date].timeIntervalSince1970), @"error": self.lastError ?: @"",
    };
    CFPreferencesSetValue(CFSTR(VP_PANEL_TOUCH_STATUS), (__bridge CFDictionaryRef)status,
                          CFSTR(VP_PANEL_TOUCH_DOMAIN), CFSTR("mobile"), kCFPreferencesAnyHost);
    CFPreferencesSynchronize(CFSTR(VP_PANEL_TOUCH_DOMAIN), CFSTR("mobile"), kCFPreferencesAnyHost);
}

/// The main display's identifier once CoreAnimation has the display.
- (NSString *)mainDisplayUUID {
    Class display = NSClassFromString(@"CADisplay");
    id main = display ? ((id (*)(Class, SEL))objc_msgSend)(display, NSSelectorFromString(@"mainDisplay")) : nil;
    SEL uniqueId = NSSelectorFromString(@"uniqueId");
    if (![main respondsToSelector:uniqueId])
        return nil;
    id value = ((id (*)(id, SEL))objc_msgSend)(main, uniqueId);
    return [value isKindOfClass:NSString.class] && [value length] ? value : nil;
}

- (void)start {
    // The display appears a little after backboardd starts. A display with
    // no identifier (every guest but this one) gets no service at all.
    self.displayUUID = [self mainDisplayUUID];
    if (!self.displayUUID) {
        if (++self.attempts < 60)
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), self.queue, ^{ [self start]; });
        return;
    }
    if (!NSClassFromString(@"HIDVirtualEventService")) {
        self.lastError = @"HIDVirtualEventService unavailable";
        [self publishStatus];
        return;
    }
    self.properties = @{
        @"PrimaryUsagePage": @0x0d, @"PrimaryUsage": @0x04,
        @"DeviceUsagePairs": @[@{@"DeviceUsagePage": @0x0d, @"DeviceUsage": @0x04}],
        @"Product": @"VPhone Panel Touch", @"Manufacturer": @"vphone",
        @"Transport": @"Virtual", @"Built-In": @YES, @"DisplayIntegrated": @YES,
        @"displayUUID": self.displayUUID,
    };
    [self createService];
}

- (void)createService {
    self.enumerated = NO;
    self.cancelling = NO;
    self.service = (id<VPhoneGyroscopeHIDService>)[NSClassFromString(@"HIDVirtualEventService") new];
    if (!self.service) {
        self.lastError = @"HIDVirtualEventService creation failed";
        [self publishStatus];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC), self.queue, ^{ [self createService]; });
        return;
    }
    self.service.delegate = self;
    [self.service setDispatchQueue:self.queue];
    __weak VPhonePanelTouchProvider *weakSelf = self;
    [self.service setCancelHandler:^{
        VPhonePanelTouchProvider *provider = weakSelf;
        if (!provider)
            return;
        provider.service = nil;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC), provider.queue,
                       ^{ [provider createService]; });
    }];
    [self.service activate];
}

// MARK: - HIDVirtualEventServiceDelegate selectors

- (id)propertyForKey:(NSString *)key forService:(id)service {
    return self.properties[key];
}

- (BOOL)setProperty:(id)value forKey:(NSString *)key forService:(id)service {
    return NO;
}

- (id)copyEventMatching:(NSDictionary *)matching forService:(id)service {
    return nil;
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
        NSLog(@"[vphone-panel-touch] HID service enumerated: %llu for display %@", self.service.serviceID,
              self.displayUUID);
    } else if (type == 11 && !self.cancelling) { // Terminated or reset
        self.enumerated = NO;
        self.cancelling = YES;
        self.lastError = @"HID service terminated; waiting to register again";
        [self.service cancel];
    }
    [self publishStatus];
}
@end

// Only an iPhone Duo guest can have its display identified.
static BOOL VPhonePanelTouchGuestIsDuo(void) {
    void *gestalt = dlopen("/usr/lib/libMobileGestalt.dylib", RTLD_NOW | RTLD_LOCAL);
    CFStringRef (*copyAnswer)(CFStringRef) = gestalt ? dlsym(gestalt, "MGCopyAnswer") : NULL;
    NSString *product = copyAnswer ? CFBridgingRelease(copyAnswer(CFSTR("ProductType"))) : nil;
    return [product isKindOfClass:NSString.class] && [product isEqualToString:@"iPhone19,4"];
}

__attribute__((constructor)) static void VPhonePanelTouchStart(void) {
    if (strcmp(getprogname(), "backboardd") != 0)
        return;
    static VPhonePanelTouchProvider *provider;
    provider = [VPhonePanelTouchProvider new];
    provider.queue = dispatch_queue_create("com.vphone.panel.touch", DISPATCH_QUEUE_SERIAL);
    dispatch_async(provider.queue, ^{
        if (VPhonePanelTouchGuestIsDuo())
            [provider start];
    });
}

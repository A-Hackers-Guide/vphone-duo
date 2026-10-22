#import "../Accelerometer/libvphoneaccelerometer.m"
#include <assert.h>
#include <stdio.h>

// Exercise subscriptions and reset without publishing a HID device or writing
// mobile's preferences on the host. The sample factory is Apple's real HID ABI.
@interface VPhoneAccelerometerTestProvider : VPhoneAccelerometerProvider
@property (nonatomic) NSUInteger timerUpdates;
@property (nonatomic) NSUInteger statusUpdates;
@end
@implementation VPhoneAccelerometerTestProvider
- (void)publishStatus { self.statusUpdates++; }
- (void)updateTimer { self.timerUpdates++; }
@end

@interface VPhoneAccelerometerTestService : NSObject
@property (nonatomic) NSUInteger cancellations;
@end
@implementation VPhoneAccelerometerTestService
- (uint64_t)serviceID { return 42; }
- (void)cancel { self.cancellations++; }
- (BOOL)dispatchEvent:(id)event { return YES; }
@end

// Runtime-shaped native peers, to check queue confinement and the actual
// setup ordering bug without loading or modifying any host system UI.
@interface BKOrientationManager : NSObject
@property (nonatomic, strong) dispatch_queue_t queue;
@property (nonatomic) NSInteger orientation;
@property (nonatomic) NSUInteger deliveries;
@property (nonatomic) NSUInteger matches;
- (void)matcher:(id)matcher servicesDidMatch:(id)services;
- (void)_queue_postUpdatedRawAccelerometerDeviceOrientation:(NSInteger)orientation;
@end
@implementation BKOrientationManager
- (void)matcher:(id)matcher servicesDidMatch:(id)services { self.matches++; }
- (void)_queue_postUpdatedRawAccelerometerDeviceOrientation:(NSInteger)orientation {
    dispatch_assert_queue(self.queue);
    self.orientation = orientation;
    self.deliveries++;
}
@end

@interface SBBacklightController : NSObject
@property (nonatomic) BOOL screenIsOn;
+ (instancetype)sharedInstanceIfExists;
@end
@implementation SBBacklightController
+ (instancetype)sharedInstanceIfExists {
    static SBBacklightController *controller;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ controller = [SBBacklightController new]; });
    return controller;
}
@end

@interface SBTraitsEmbeddedDisplayPipelineManager : NSObject
@property (nonatomic) BOOL backlightIsOn;
@property (nonatomic) BOOL eventsEnabled;
@property (nonatomic) BOOL deferring;
@property (nonatomic) NSUInteger setups;
- (void)setupDefaultPipelineForArbiter:(id)arbiter;
- (void)_updateOrientationEventsEnabledState;
- (void)_updateOrientationInputsDeferralAnimated:(BOOL)animated;
@end
@implementation SBTraitsEmbeddedDisplayPipelineManager
- (void)setupDefaultPipelineForArbiter:(id)arbiter {
    self.setups++;
    self.backlightIsOn = NO;
    [self _updateOrientationEventsEnabledState];
    self.backlightIsOn = [SBBacklightController sharedInstanceIfExists].screenIsOn;
}
- (void)_updateOrientationEventsEnabledState { self.eventsEnabled = self.backlightIsOn; }
- (void)_updateOrientationInputsDeferralAnimated:(BOOL)animated { self.deferring = !self.backlightIsOn; }
@end

int main(void) {
    @autoreleasepool {
        int degrees = -1;
        for (id invalid in @[@YES, @"90", @-90, @360, @90.5, @(NAN), @(INFINITY), NSNull.null]) {
            assert(!VPhoneAccelerometerDecode(invalid, &degrees));
            assert(degrees == 0);
        }
        assert(!VPhoneAccelerometerDecode(nil, &degrees) && degrees == 0);
        NSArray *specs = @[@"portrait", @"LEFT", @"portrait-upside-down", @"right"];
        double expectedX[] = {0, -1, 0, 1}, expectedY[] = {-1, 0, 1, 0};
        assert(VPhoneAccelerometerDegrees(@"face-up") == -1);
        assert(VPhoneAccelerometerInterval(@500) == 5000);
        assert(VPhoneAccelerometerInterval(@20000) == 20000);
        assert(VPhoneAccelerometerInterval(@1e30) == 1000000);
        for (id invalid in @[@YES, @"20000", @-1, @0, @(NAN), @(INFINITY)])
            assert(VPhoneAccelerometerInterval(invalid) == 0);

        assert(dlopen("/System/Library/PrivateFrameworks/HID.framework/HID", RTLD_NOW | RTLD_LOCAL));
        VPhoneAccelerometerTestProvider *provider = [VPhoneAccelerometerTestProvider new];
        provider.eventClass = (Class<VPhoneAccelerometerHIDEvent>)NSClassFromString(@"HIDEvent");
        provider.properties = [NSMutableDictionary new];
        VPhoneAccelerometerTestService *service = [VPhoneAccelerometerTestService new];
        NSObject *staleService = [NSObject new];
        provider.service = (id)service;
        for (int index = 0; index < 4; index++) {
            assert(VPhoneAccelerometerDecode(@(index * 90), &degrees));
            assert(VPhoneAccelerometerDegrees(specs[index]) == degrees);
            provider.degrees = degrees;
            id<VPhoneAccelerometerHIDEvent> event = [provider sample];
            assert(event && event.timestamp > 0);
            assert(event.accelerometerX == expectedX[index]);
            assert(event.accelerometerY == expectedY[index]);
            assert(event.accelerometerZ == 0 && event.accelerometerSequence == (uint32_t)index);
        }
        assert(![provider copyEventMatching:nil forService:service]);
        [provider notification:10 withProperty:nil forService:staleService];
        assert(!provider.enumerated && provider.statusUpdates == 0);
        [provider notification:10 withProperty:nil forService:service];
        assert(provider.enumerated && provider.statusUpdates == 1);
        assert([provider copyEventMatching:@{@"EventType": @13} forService:service]);
        assert(![provider copyEventMatching:@{@"EventType": @20} forService:service]);
        assert(![provider copyEventMatching:nil forService:staleService]);
        assert([provider setProperty:@20000 forKey:@"ReportInterval" forService:service]);
        assert(provider.interval == 20000);
        assert(![provider setProperty:@0 forKey:@"ReportInterval" forService:staleService]);
        assert(provider.interval == 20000);
        assert([provider setProperty:@0 forKey:@"ReportInterval" forService:service]);
        assert(provider.interval == 0);
        assert([provider setProperty:@100 forKey:@"BatchInterval" forService:service]);
        assert(![provider setProperty:@YES forKey:@"Unsupported" forService:service]);
        [provider notification:11 withProperty:nil forService:service];
        [provider notification:11 withProperty:nil forService:service];
        assert(!provider.enumerated && provider.cancelling && service.cancellations == 1);
        assert(![provider copyEventMatching:nil forService:service]);
        puts("Accelerometer gravity, real HID samples and subscription tests passed");

        VPhoneOrientationSinkInstall(nil, nil);
        BKOrientationManager *manager = [BKOrientationManager new];
        manager.queue = dispatch_queue_create("com.vphone.orientation.sink-test", DISPATCH_QUEUE_SERIAL);
        dispatch_sync(manager.queue, ^{ [manager matcher:nil servicesDidMatch:@[]]; });
        dispatch_sync(manager.queue, ^{ assert(manager.orientation == 1 && manager.deliveries == 1 && manager.matches == 1); });
        NSInteger nativeOrientations[] = {1, 4, 2, 3};
        for (int index = 0; index < 4; index++) {
            provider.degrees = index * 90;
            VPhoneOrientationSinkPublish([provider sample]);
            NSInteger expectedOrientation = nativeOrientations[index];
            dispatch_sync(manager.queue, ^{ assert(manager.orientation == expectedOrientation); });
        }
        NSUInteger deliveries = manager.deliveries;
        VPhoneOrientationSinkPublish([provider sample]);
        // Flat and ambiguous samples must not create a made-up direction.
        VPhoneOrientationSinkPublish([provider.eventClass accelerometerEvent:1 x:0 y:0 z:1 options:0]);
        VPhoneOrientationSinkPublish([provider.eventClass accelerometerEvent:2 x:0.6 y:0.6 z:0 options:0]);
        dispatch_sync(manager.queue, ^{ assert(manager.deliveries == deliveries); });
        assert([VPhoneOrientationSinkStatus()[@"ready"] boolValue]);
        assert([VPhoneOrientationSinkStatus()[@"device_orientation"] integerValue] == 3);

        SBBacklightController *backlight = [SBBacklightController sharedInstanceIfExists];
        backlight.screenIsOn = YES;
        SBTraitsEmbeddedDisplayPipelineManager *pipeline = [SBTraitsEmbeddedDisplayPipelineManager new];
        [pipeline setupDefaultPipelineForArbiter:nil];
        assert(!pipeline.eventsEnabled); // Native ordering reproduces the bug.
        VPhoneOrientationGateInstall();
        [pipeline setupDefaultPipelineForArbiter:nil];
        assert(pipeline.eventsEnabled && !pipeline.deferring && pipeline.setups == 2);
        backlight.screenIsOn = NO;
        [pipeline setupDefaultPipelineForArbiter:nil];
        assert(!pipeline.eventsEnabled && pipeline.deferring && pipeline.setups == 3);
        puts("Device orientation sink queue, deduplication and backlight seed regression tests passed");
    }
    return 0;
}

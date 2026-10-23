#import <Foundation/Foundation.h>
#define VP_HOMEPOD_DEBUG_TESTING 1
#import "../Native/vphoned_homepod_debug.m"

static id received;
static BOOL neverReply;
static void (^lateReply)(NSDictionary *);

// Independently recovered method encodings from SoundBoardServices in
// AudioAccessory5,1 27.0 (24J361), SHA-256
// 5e5d68df84c8c3a54669a1618ea1cb8f3d12996b4ffe5d9be3828b62917cf41a.
// Preserve this donor fixture separately from the bridge's argument catalog:
// matching representative stub methods alone cannot establish full coverage.
static NSDictionary<NSString *, NSString *> *donorMethodEncodings(void) {
    return @{
        @"getAllDebugInfo:": @"v24@0:8@?16",
        @"getSelectDebugInfo:reply:": @"v32@0:8@16@?24",
        @"getLEDInfo:": @"v24@0:8@?16",
        @"sendLEDCommand:": @"v24@0:8@16",
        @"render:": @"v24@0:8@16",
        @"setLEDContents:": @"v24@0:8@16",
        @"setBootSpinner:": @"v20@0:8B16",
        @"getVolume:": @"v24@0:8@?16",
        @"setVolume:": @"v20@0:8f16",
        @"playTone:": @"v20@0:8I16",
        @"stopTone:": @"v20@0:8I16",
        @"siriSay:": @"v24@0:8@16",
        @"sendButtonCommand:": @"v24@0:8@16",
        @"getTuningInfo:": @"v24@0:8@?16",
        @"setTuningInfoOnBox:at:withValue:": @"v36@0:8@16@24f32",
        @"getUserDefaults:": @"v24@0:8@?16",
        @"setUserDefaults:withValue:": @"v32@0:8@16@24",
        @"resetUserDefault:": @"v24@0:8@16",
        @"resetAllUserDefaults": @"v16@0:8",
        @"getFeatureFlags:": @"v24@0:8@?16",
        @"setFeatureFlags:": @"v24@0:8@16",
        @"triggerWiFiCoreCapture:": @"v24@0:8@16",
        @"setWifiEnabled:": @"v20@0:8B16",
        @"disassociateCurrentNetwork": @"v16@0:8",
        @"disassociateNetworkWithName:": @"v24@0:8@16",
        @"injectSWUpdateToHome:": @"v24@0:8@16",
        @"setHomeUpdateState:": @"v24@0:8q16",
        @"clearHomeSWUpdate": @"v16@0:8",
        @"suScanForSoftwareUpdate": @"v16@0:8",
    };
}
@interface HPButtonEvent : NSObject
@property(nonatomic) uint64_t button;
@property(nonatomic) uint64_t action;
@property(nonatomic) int64_t numberOfTaps;
@property(nonatomic) uint64_t startMachTime;
@property(nonatomic) BOOL deviceSideways;
@property(nonatomic) BOOL coalesced;
@property(nonatomic, readonly) NSData *data;
@end
@implementation HPButtonEvent
- (NSData *)data {
    return [NSJSONSerialization dataWithJSONObject:@{@"button": @(self.button), @"action": @(self.action), @"numberOfTaps": @(self.numberOfTaps), @"startMachTime": @(self.startMachTime), @"deviceSideways": @(self.deviceSideways), @"coalesced": @(self.coalesced)} options:0 error:NULL];
}
@end
@interface SBSDebugInterface : NSObject
@end
@implementation SBSDebugInterface
- (void)getAllDebugInfo:(void (^)(NSDictionary *))reply {
    if (neverReply) lateReply = [reply copy];
    else reply(@{@"nested": @[@1, @YES], @"data": [@"test" dataUsingEncoding:NSUTF8StringEncoding]});
}
- (void)getSelectDebugInfo:(NSArray *)keys reply:(void (^)(NSDictionary *))reply { received = keys; reply(@{@"selected": keys}); }
- (void)getVolume:(void (^)(float))reply { reply(0.375f); }
- (void)setVolume:(float)value { received = @(value); }
- (void)setBootSpinner:(BOOL)value { received = @(value); }
- (void)playTone:(uint32_t)value { received = @(value); }
- (void)setHomeUpdateState:(int64_t)value { received = @(value); }
- (void)setTuningInfoOnBox:(NSString *)box at:(NSString *)name withValue:(float)value { received = @[box, name, @(value)]; }
- (void)setUserDefaults:(NSString *)name withValue:(NSString *)value { received = @[name, value]; }
- (void)sendButtonCommand:(NSData *)data { received = data; }
- (void)setLEDContents:(NSArray *)contents { received = contents; }
- (void)resetAllUserDefaults { received = @"reset"; }
@end

static NSDictionary *call(NSString *name, NSDictionary *arguments) {
    NSData *data = [NSJSONSerialization dataWithJSONObject:arguments options:0 error:NULL];
    NSString *text = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    char *json = vp_homepod_debug_copy_json(name.UTF8String, text.UTF8String);
    assert(json);
    NSDictionary *value = [NSJSONSerialization JSONObjectWithData:[NSData dataWithBytes:json length:strlen(json)] options:0 error:NULL];
    free(json);
    assert(value);
    return value;
}
int main(void) {
    @autoreleasepool {
        NSDictionary *catalog = call(@"catalog", @{});
        assert([catalog[@"ok"] boolValue]);
        NSArray *entries = catalog[@"result"][@"operations"];
        assert(entries.count == 29);
        assert([catalog[@"result"][@"animations"] count] == 25);
        assert([catalog[@"result"][@"phases"] count] == 20);
        NSMutableSet *selectors = NSMutableSet.set;
        NSDictionary *donor = donorMethodEncodings();
        for (NSDictionary *entry in entries) {
            assert(![selectors containsObject:entry[@"id"]]); [selectors addObject:entry[@"id"]];
            assert(entry[@"title"] && entry[@"group"] && entry[@"arguments"] && entry[@"reply"]);
            NSString *encoding = donor[entry[@"id"]];
            assert(encoding);
            assert(matchesSignature([NSMethodSignature signatureWithObjCTypes:encoding.UTF8String], entry));
        }
        assert([selectors isEqualToSet:[NSSet setWithArray:donor.allKeys]]);
        NSDictionary *reply = call(@"getAllDebugInfo:", @{});
        assert([reply[@"ok"] boolValue]);
        assert([reply[@"result"][@"value"][@"data"][@"base64"] isEqual:@"dGVzdA=="]);
        reply = call(@"getVolume:", @{});
        assert([reply[@"result"][@"value"] doubleValue] == 0.375);
        assert([call(@"getSelectDebugInfo:reply:", @{@"keys": @[@"a", @"b"]})[@"ok"] boolValue]);
        assert([received isEqual:(@[@"a", @"b"])]);
        assert([call(@"setVolume:", @{@"value": @0.625})[@"result"][@"submitted"] boolValue]);
        assert([received doubleValue] == 0.625);
        assert(![call(@"setVolume:", @{@"value": @2})[@"ok"] boolValue]);
        assert(![call(@"setVolume:", @{@"value": @YES})[@"ok"] boolValue]);
        assert([call(@"setBootSpinner:", @{@"enabled": @YES})[@"ok"] boolValue]);
        assert([received boolValue]);
        assert(![call(@"setBootSpinner:", @{@"enabled": @1})[@"ok"] boolValue]);
        assert([call(@"playTone:", @{@"tone": @(UINT32_MAX)})[@"ok"] boolValue]);
        assert([received unsignedIntValue] == UINT32_MAX);
        assert(![call(@"playTone:", @{@"tone": @-1})[@"ok"] boolValue]);
        assert(![call(@"playTone:", @{@"tone": @1.5})[@"ok"] boolValue]);
        assert(![call(@"playTone:", @{@"tone": @YES})[@"ok"] boolValue]);
        assert([call(@"setHomeUpdateState:", @{@"state": @(INT64_MIN)})[@"ok"] boolValue]);
        assert([received longLongValue] == INT64_MIN);
        assert(![call(@"setHomeUpdateState:", @{@"state": @YES})[@"ok"] boolValue]);
        assert([call(@"setTuningInfoOnBox:at:withValue:", @{@"box": @"box", @"parameter": @"parameter", @"value": @0.25})[@"ok"] boolValue]);
        assert([received isEqual:(@[@"box", @"parameter", @0.25])]);
        assert([call(@"setUserDefaults:withValue:", @{@"name": @"key", @"value": @"1"})[@"ok"] boolValue]);
        assert([received isEqual:(@[@"key", @"1"])]);
        assert([call(@"sendButtonCommand:", @{@"event": @{@"base64": @"dGVzdA=="}})[@"ok"] boolValue]);
        assert([received isEqual:[@"test" dataUsingEncoding:NSUTF8StringEncoding]]);
        assert(![call(@"sendButtonCommand:", @{@"event": @{@"base64": @"***"}})[@"ok"] boolValue]);
        NSMutableDictionary *event = [@{@"button": @3, @"action": @2, @"numberOfTaps": @1, @"startMachTime": @(UINT64_MAX), @"deviceSideways": @NO, @"coalesced": @YES} mutableCopy];
        assert([call(@"sendButtonCommand:", @{@"event": event})[@"ok"] boolValue]);
        NSDictionary *decoded = [NSJSONSerialization JSONObjectWithData:received options:0 error:NULL];
        assert([decoded isEqual:event]);
        event[@"button"] = @-1;
        assert(![call(@"sendButtonCommand:", @{@"event": event})[@"ok"] boolValue]);
        event[@"button"] = @1.5;
        assert(![call(@"sendButtonCommand:", @{@"event": event})[@"ok"] boolValue]);
        event[@"button"] = @3;
        event[@"deviceSideways"] = @1;
        assert(![call(@"sendButtonCommand:", @{@"event": event})[@"ok"] boolValue]);
        NSArray *frames = @[@{@"LedValuesTimestamp": @0, @"LedValuesData": @{@"fill": @[@0.25, @0.5, @1]}}];
        assert([call(@"setLEDContents:", @{@"contents": frames})[@"ok"] boolValue]);
        NSData *pixels = received[0][@"LedValuesData"];
        assert(pixels.length == 40 * 3 * sizeof(float));
        const float *channels = pixels.bytes;
        assert(channels[0] == 0.25 && channels[1] == 0.5 && channels[2] == 1);
        frames = @[@{@"LedValuesTimestamp": @0, @"LedValuesData": @{@"base64": [pixels base64EncodedStringWithOptions:0]}}];
        assert([call(@"setLEDContents:", @{@"contents": frames})[@"ok"] boolValue]);
        assert([received[0][@"LedValuesData"] isEqual:pixels]);
        assert(![call(@"setLEDContents:", @{@"contents": @[]})[@"ok"] boolValue]);
        assert(![call(@"setLEDContents:", @{@"contents": @[@{@"LedValuesTimestamp": @0, @"LedValuesData": @{@"base64": @""}}]})[@"ok"] boolValue]);
        assert(![call(@"setLEDContents:", @{@"contents": @[@{@"LedValuesTimestamp": @YES, @"LedValuesData": @{@"fill": @[@0, @0, @0]}}]})[@"ok"] boolValue]);
        assert([call(@"resetAllUserDefaults", @{})[@"ok"] boolValue]);
        assert([received isEqual:@"reset"]);
        assert(![call(@"performSelector:", @{})[@"ok"] boolValue]);
        assert(![call(@"getLEDInfo:", @{})[@"ok"] boolValue]); // Missing native ABI is refused.
        neverReply = YES;
        NSDate *start = NSDate.date;
        assert(![call(@"getAllDebugInfo:", @{})[@"ok"] boolValue]);
        assert(-start.timeIntervalSinceNow >= 2.9 && -start.timeIntervalSinceNow < 4.0);
        // An old XPC connection may deliver its reply after the deadline. It
        // must neither affect the next request nor signal a reused semaphore.
        assert(lateReply);
        lateReply(@{@"stale": @YES});
        lateReply = nil;
        neverReply = NO;
        reply = call(@"getAllDebugInfo:", @{});
        assert([reply[@"ok"] boolValue]);
        assert(reply[@"result"][@"value"][@"stale"] == nil);
        assert([reply[@"result"][@"value"][@"data"][@"base64"] isEqual:@"dGVzdA=="]);
        puts("HomePod debug bridge tests passed (all 29 donor ABIs, argument forwarding, replies, rejection, timeout and late reply). ");
    }
}

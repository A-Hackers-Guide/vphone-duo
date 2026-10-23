#define VP_HOMEPOD_SOUND_GLOW_TESTING 1
#import "../HomePodDisplay/VPHomePodSoundGlow.m"
#include <assert.h>

BOOL VPSoundGlowTestEnabled;
BOOL VPSoundGlowTestNowPlaying;

@interface _TtC13NowPlayingCap24AccessorySettingProvider : NSObject
@property (nonatomic) NSInteger mediaUI;
@end
@implementation _TtC13NowPlayingCap24AccessorySettingProvider
@end

@interface WrongSoundGlowABI : NSObject
- (BOOL)mediaUI;
- (void)setMediaUI:(BOOL)value;
@end
@implementation WrongSoundGlowABI
- (BOOL)mediaUI { return NO; }
- (void)setMediaUI:(BOOL)value { (void)value; }
@end

@interface MRDestination : NSObject
@property (nonatomic, copy) NSString *outputDeviceUID;
+ (id)localDestination;
@end
@implementation MRDestination
+ (id)localDestination {
    static MRDestination *local;
    if (!local) { local = [self new]; local.outputDeviceUID = @"local-origin"; }
    return local;
}
@end

@interface MRDeviceInfo : NSObject
- (id)deviceUID;
@end
@implementation MRDeviceInfo
- (id)deviceUID { return @"own-accessory"; }
@end

@interface MRDeviceInfoRequest : NSObject
+ (id)localDeviceInfo;
@end
@implementation MRDeviceInfoRequest
+ (id)localDeviceInfo { return [MRDeviceInfo new]; }
@end

@interface MRPlaybackQueueRequest : NSObject
@property (nonatomic, strong) id receivedDestination;
@property (nonatomic) NSUInteger calls;
- (void)performRequestForDestination:(id)destination completion:(void (^)(id, id))completion;
@end
@implementation MRPlaybackQueueRequest
- (void)performRequestForDestination:(id)destination completion:(void (^)(id, id))completion {
    self.receivedDestination = destination;
    self.calls++;
    if (completion) completion(@"native-artwork", nil);
}
@end

int main(void) { @autoreleasepool {
    Class provider = _TtC13NowPlayingCap24AccessorySettingProvider.class;
    assert(!VPSoundGlowNativeABI(Nil)); // 27.0 has no accessory-setting provider.
    assert(!VPSoundGlowNativeABI(WrongSoundGlowABI.class));
    assert(VPSoundGlowNativeABI(provider));
    assert(VPSoundGlowArtworkABI());
    assert(!VPHomePodSoundGlowInstall());
    VPSoundGlowTestEnabled = YES;
    assert(!VPHomePodSoundGlowInstall()); // SoundBoard must not get this hook.
    VPSoundGlowTestNowPlaying = YES;
    assert(VPHomePodSoundGlowInstall());
    assert(VPHomePodSoundGlowInstall()); // No recursion or double replacement.
    _TtC13NowPlayingCap24AccessorySettingProvider *settings = [provider new];
    assert(settings.mediaUI == 1);
    settings.mediaUI = 7; // Native Home updates still reach the original setter.
    assert(settings.mediaUI == 1);
    VPSoundGlowTestEnabled = NO;
    assert(settings.mediaUI == 7); // Opt-out restores the actual setting.
    settings.mediaUI = 0;
    assert(settings.mediaUI == 0);
    VPSoundGlowTestEnabled = YES;
    assert(settings.mediaUI == 1);
    MRPlaybackQueueRequest *request = [MRPlaybackQueueRequest new];
    MRDestination *own = [MRDestination new]; own.outputDeviceUID = @"own-accessory";
    __block id reply;
    [request performRequestForDestination:own completion:^(id value, id error) {
        assert(!error); reply = value;
    }];
    assert(request.receivedDestination == [MRDestination localDestination]);
    assert([reply isEqual:@"native-artwork"] && request.calls == 1);
    MRDestination *remote = [MRDestination new]; remote.outputDeviceUID = @"another-device";
    [request performRequestForDestination:remote completion:nil];
    assert(request.receivedDestination == remote);
    [request performRequestForDestination:nil completion:nil];
    assert(request.receivedDestination == nil);
    VPSoundGlowTestEnabled = NO;
    [request performRequestForDestination:own completion:nil];
    assert(request.receivedDestination == own && request.calls == 4);
    puts("HomePod Sound Glow native setting, process isolation, opt-out and ABI tests passed");
} return 0; }

#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <objc/message.h>

// 24K120 adds native artwork extraction and CAPAnimationEffect.media to
// NowPlayingCap. Its Home accessory setting defaults to off on an unpaired VM.
// Select that existing renderer in this process only; never generate frames or
// change MobileGestalt identity, shared audio sessions or Home preferences.
static NSInteger (*VPSoundGlowOriginalMediaUI)(id, SEL);
static void (*VPSoundGlowOriginalArtworkRequest)(id, SEL, id, id);

static BOOL VPSoundGlowEnabled(void) {
#ifdef VP_HOMEPOD_SOUND_GLOW_TESTING
    extern BOOL VPSoundGlowTestEnabled;
    return VPSoundGlowTestEnabled;
#else
    return [[NSDictionary dictionaryWithContentsOfFile:@"/usr/share/vphone/HomePodSoundGlow.plist"][@"Enabled"] isEqual:@YES];
#endif
}

static BOOL VPSoundGlowIsNowPlaying(void) {
#ifdef VP_HOMEPOD_SOUND_GLOW_TESTING
    extern BOOL VPSoundGlowTestNowPlaying;
    return VPSoundGlowTestNowPlaying;
#else
    return [NSProcessInfo.processInfo.processName isEqualToString:@"NowPlayingCap"];
#endif
}

static BOOL VPSoundGlowSignature(Class cls, SEL selector, const char *result,
                                 NSArray<NSString *> *arguments) {
    Method method = class_getInstanceMethod(cls, selector);
    if (!method) return NO;
    NSMethodSignature *signature = [NSMethodSignature signatureWithObjCTypes:method_getTypeEncoding(method)];
    if (signature.numberOfArguments != arguments.count + 2 || strcmp(signature.methodReturnType, result)) return NO;
    for (NSUInteger i = 0; i < arguments.count; i++) {
        if (strcmp([signature getArgumentTypeAtIndex:i + 2], arguments[i].UTF8String)) return NO;
    }
    return YES;
}

static BOOL VPSoundGlowNativeABI(Class cls) {
    return VPSoundGlowSignature(cls, NSSelectorFromString(@"mediaUI"), @encode(NSInteger), @[]) &&
        VPSoundGlowSignature(cls, NSSelectorFromString(@"setMediaUI:"), @encode(void), @[@(@encode(NSInteger))]);
}

static NSInteger VPSoundGlowMediaUI(id receiver, SEL selector) {
    // Native 24K120 compares this setting to exactly 1 before fetching artwork
    // and choosing its expressive media/soundscape effects. Opt-out exposes the
    // real accessory setting again, including updates received from Home.
    return VPSoundGlowEnabled() ? 1 : VPSoundGlowOriginalMediaUI(receiver, selector);
}

static id VPSoundGlowObject(id receiver, NSString *selector) {
    return ((id (*)(id, SEL))objc_msgSend)(receiver, NSSelectorFromString(selector));
}

static void VPSoundGlowArtworkRequest(id receiver, SEL selector, id destination, id completion) {
    id target = destination;
    if (VPSoundGlowEnabled()) {
        // Native 24K120 ArtworkFetcher addresses MRDeviceInfoRequest's own UID.
        // An unpaired virtual accessory has no discoverable endpoint for that
        // UID. Use MediaRemote's local origin for this one local request; keep
        // Apple's identifiers, dimensions, response and artwork pipeline.
        id info = VPSoundGlowObject(NSClassFromString(@"MRDeviceInfoRequest"), @"localDeviceInfo");
        id ownUID = VPSoundGlowObject(info, @"deviceUID");
        id requestedUID = [destination respondsToSelector:NSSelectorFromString(@"outputDeviceUID")]
            ? VPSoundGlowObject(destination, @"outputDeviceUID") : nil;
        if ([ownUID isKindOfClass:NSString.class] && [ownUID length] && [ownUID isEqual:requestedUID]) {
            id local = VPSoundGlowObject(NSClassFromString(@"MRDestination"), @"localDestination");
            if (local) target = local;
        }
    }
    VPSoundGlowOriginalArtworkRequest(receiver, selector, target, completion);
}

static BOOL VPSoundGlowArtworkABI(void) {
    Class request = NSClassFromString(@"MRPlaybackQueueRequest");
    Class destination = NSClassFromString(@"MRDestination");
    Class infoRequest = NSClassFromString(@"MRDeviceInfoRequest");
    Class info = NSClassFromString(@"MRDeviceInfo");
    return VPSoundGlowSignature(request, NSSelectorFromString(@"performRequestForDestination:completion:"),
                                @encode(void), @[@(@encode(id)), @"@?"]) &&
        VPSoundGlowSignature(object_getClass(destination), NSSelectorFromString(@"localDestination"), @encode(id), @[]) &&
        VPSoundGlowSignature(destination, NSSelectorFromString(@"outputDeviceUID"), @encode(id), @[]) &&
        VPSoundGlowSignature(object_getClass(infoRequest), NSSelectorFromString(@"localDeviceInfo"), @encode(id), @[]) &&
        VPSoundGlowSignature(info, NSSelectorFromString(@"deviceUID"), @encode(id), @[]);
}

BOOL VPHomePodSoundGlowInstall(void) {
    static BOOL installed;
    if (!VPSoundGlowIsNowPlaying() || !VPSoundGlowEnabled()) return NO;
    Class provider = NSClassFromString(@"_TtC13NowPlayingCap24AccessorySettingProvider");
    if (!VPSoundGlowNativeABI(provider)) {
        NSLog(@"vphone HomePod Sound Glow: native accessory-setting ABI unavailable");
        return NO;
    }
    if (installed) return YES;
    Method getter = class_getInstanceMethod(provider, NSSelectorFromString(@"mediaUI"));
    VPSoundGlowOriginalMediaUI = (void *)method_setImplementation(getter, (IMP)VPSoundGlowMediaUI);
    if (VPSoundGlowArtworkABI()) {
        Method request = class_getInstanceMethod(NSClassFromString(@"MRPlaybackQueueRequest"),
            NSSelectorFromString(@"performRequestForDestination:completion:"));
        VPSoundGlowOriginalArtworkRequest = (void *)method_setImplementation(request, (IMP)VPSoundGlowArtworkRequest);
        NSLog(@"vphone HomePod Sound Glow: local artwork request adapter ready");
    } else {
        NSLog(@"vphone HomePod Sound Glow: native artwork request ABI unavailable");
    }
    installed = YES;
    NSLog(@"vphone HomePod Sound Glow: native media renderer enabled");
    return YES;
}

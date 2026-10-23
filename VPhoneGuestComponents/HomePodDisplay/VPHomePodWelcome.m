#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#include <dlfcn.h>
#import "VPHomePodWelcomeState.h"

// Runs in SoundBoard, beside the MiniDisplay identity adapter. All rendering,
// playback, Siri session ownership and speech synthesis remain Apple's. See
// Research/Firmware/homepod_welcome.md for the donor APIs and live-test limits.
@protocol VPHomePodWelcomeNative
@optional
- (id)activityManager;
- (id)displayService;
- (id)siriManager;
- (id)uiTonePlaybackManager;
- (id)activityWithName:(NSString *)name;
- (id)foregroundedActivity;
- (NSString *)activityName;
- (NSUInteger)activeMediaCount;
- (NSDictionary *)diagnosticsInfo;
- (BOOL)startupComplete;
- (BOOL)siriEnabled;
- (BOOL)deviceNeedsSetup;
- (BOOL)localSessionActive;
- (BOOL)remoteSessionActive;
- (BOOL)siriUIEnabled;
- (NSInteger)currentSessionState;
- (void)setLocalSessionActive:(BOOL)active;
- (void)play:(uint32_t)tone completion:(void (^)(NSError *))completion;
- (void)say:(NSString *)text completion:(void (^)(NSError *))completion;
@end

static NSString *const VPHomePodWelcomePhrase = @"Hi, I'm Siri. It sure is great to be running in a virtual machine!";
static NSString *(*VPWelcomeSessionStateName)(NSInteger);

static BOOL VPWelcomeSignature(id object, SEL selector, const char *result, NSArray<NSString *> *arguments) {
    NSMethodSignature *signature = [object methodSignatureForSelector:selector];
    if (!signature || strcmp(signature.methodReturnType, result) || signature.numberOfArguments != arguments.count + 2) return NO;
    for (NSUInteger i = 0; i < arguments.count; i++) {
        if (strcmp([signature getArgumentTypeAtIndex:i + 2], arguments[i].UTF8String)) return NO;
    }
    return YES;
}

static BOOL VPWelcomeObjectGetter(id object, SEL selector) {
    return VPWelcomeSignature(object, selector, @encode(id), @[]);
}

static BOOL VPWelcomeBoolGetter(id object, SEL selector) {
    return VPWelcomeSignature(object, selector, @encode(BOOL), @[]);
}

typedef NS_ENUM(NSUInteger, VPHomePodWelcomePhase) {
    VPHomePodWelcomeWaiting, VPHomePodWelcomeTone, VPHomePodWelcomePause,
    VPHomePodWelcomeSpeech, VPHomePodWelcomeStopped,
};

@interface VPHomePodWelcome : NSObject
@property (nonatomic, weak) id<VPHomePodWelcomeNative> board;
@property (nonatomic, strong) id<VPHomePodWelcomeNative> siri;
@property (nonatomic, strong) id<VPHomePodWelcomeNative> flourish;
@property (nonatomic, strong) VPHomePodWelcomeState *state;
@property (nonatomic, copy) NSString *policyPath;
@property (nonatomic, strong) dispatch_source_t timer;
@property (nonatomic) VPHomePodWelcomePhase phase;
- (instancetype)initWithBoard:(id)board directory:(NSString *)directory policy:(NSString *)policy;
- (void)poll;
@end

@implementation VPHomePodWelcome
- (instancetype)initWithBoard:(id)board directory:(NSString *)directory policy:(NSString *)policy {
    if ((self = [super init])) {
        _board = board;
        _state = [[VPHomePodWelcomeState alloc] initWithDirectory:directory];
        _policyPath = [policy copy];
    }
    return self;
}

- (BOOL)enabled {
    NSDictionary *policy = [NSDictionary dictionaryWithContentsOfFile:self.policyPath];
    return [policy[@"Enabled"] isEqual:@YES];
}

- (void)record:(NSString *)status error:(NSError *)error {
    NSMutableDictionary *fields = NSMutableDictionary.dictionary;
    if (error) {
        fields[@"ErrorDomain"] = error.domain;
        fields[@"ErrorCode"] = @(error.code);
        fields[@"ErrorDescription"] = error.localizedDescription;
    }
    NSError *writeError = nil;
    if (![self.state writeStatus:status fields:fields error:&writeError]) {
        NSLog(@"vphone HomePod welcome: cannot record %@: %@", status, writeError);
    }
    NSLog(@"vphone HomePod welcome: %@%@", status, error ? [@": " stringByAppendingString:error.description] : @"");
}

- (void)stop:(NSString *)status error:(NSError *)error {
    self.phase = VPHomePodWelcomeStopped;
    if (self.timer) { dispatch_source_cancel(self.timer); self.timer = nil; }
    if (self.flourish) {
        // The coordinated setter clears ownership and invokes Identify's
        // endLocalSessionActivity cleanup. Calling that callback directly
        // leaves the activity active and it resurfaces after Siri finishes.
        [self.flourish setLocalSessionActive:NO];
        self.flourish = nil;
    }
    [self record:status error:error];
}

- (BOOL)nativeReady {
    id<VPHomePodWelcomeNative> board = self.board;
    Class setup = NSClassFromString(@"SBSetupController");
    if (!VPWelcomeBoolGetter(setup, @selector(deviceNeedsSetup)) ||
        [(id<VPHomePodWelcomeNative>)setup deviceNeedsSetup]) return NO;
    for (NSString *name in @[@"activityManager", @"displayService", @"siriManager", @"uiTonePlaybackManager"]) {
        if (!VPWelcomeObjectGetter(board, NSSelectorFromString(name))) return NO;
    }
    id<VPHomePodWelcomeNative> display = [board displayService];
    if (!VPWelcomeBoolGetter(display, @selector(startupComplete)) || ![display startupComplete] ||
        !VPWelcomeObjectGetter(display, @selector(diagnosticsInfo)) ||
        ![[display diagnosticsInfo][@"DrawingEnabled"] boolValue]) return NO;
    id<VPHomePodWelcomeNative> manager = [board activityManager];
    if (!VPWelcomeSignature(manager, @selector(activityWithName:), @encode(id), @[@(@encode(id))]) ||
        !VPWelcomeObjectGetter(manager, @selector(foregroundedActivity))) return NO;
    id<VPHomePodWelcomeNative> foreground = [manager foregroundedActivity];
    // NowPlayingCap is present even while idle. Leave live media and all other
    // foreground activities alone; our native Identify activity has priority 22.
    if (foreground && (!VPWelcomeObjectGetter(foreground, @selector(activityName)) ||
        ![[foreground activityName] isEqual:@"NowPlayingCap"] ||
        !VPWelcomeSignature(manager, @selector(activeMediaCount), @encode(NSUInteger), @[]) || [manager activeMediaCount])) return NO;
    id<VPHomePodWelcomeNative> identify = [manager activityWithName:@"Identify"];
    id<VPHomePodWelcomeNative> siriActivity = [manager activityWithName:@"Siri"];
    if (!VPWelcomeBoolGetter(identify, @selector(localSessionActive)) || [identify localSessionActive] ||
        !VPWelcomeBoolGetter(identify, @selector(remoteSessionActive)) || [identify remoteSessionActive] ||
        !VPWelcomeSignature(identify, @selector(setLocalSessionActive:), @encode(void), @[@(@encode(BOOL))]) ||
        !VPWelcomeBoolGetter(siriActivity, @selector(siriUIEnabled)) || ![siriActivity siriUIEnabled]) return NO;
    id<VPHomePodWelcomeNative> siri = [board siriManager];
    if (!VPWelcomeBoolGetter(siri, @selector(siriEnabled)) || ![siri siriEnabled] ||
        !VPWelcomeSignature(siri, @selector(currentSessionState), @encode(NSInteger), @[]) ||
        !VPWelcomeSessionStateName || ![VPWelcomeSessionStateName([siri currentSessionState]) isEqual:@"idle"] ||
        !VPWelcomeSignature(siri, @selector(say:completion:), @encode(void), @[@(@encode(id)), @"@?"]) ||
        !VPWelcomeSignature([board uiTonePlaybackManager], @selector(play:completion:), @encode(void), @[@(@encode(uint32_t)), @"@?"])) return NO;
    self.siri = siri;
    // Do not enable Buddy's debug-only renderer. Identify's normal coordinated
    // activity supplies a native animated ring, without its separate tone 6.
    self.flourish = identify;
    return YES;
}

- (void)poll {
    if (self.phase != VPHomePodWelcomeWaiting) return;
    if (![self enabled]) {
        self.phase = VPHomePodWelcomeStopped;
        if (self.timer) { dispatch_source_cancel(self.timer); self.timer = nil; }
        return; // Opt-out must not create or replace any consumption state.
    }
    if (![self nativeReady]) return;
    NSError *claimError = nil;
    if (![self.state claimWithError:&claimError]) {
        self.phase = VPHomePodWelcomeStopped;
        if (self.timer) { dispatch_source_cancel(self.timer); self.timer = nil; }
        self.flourish = nil;
        if (claimError) NSLog(@"vphone HomePod welcome: cannot claim: %@", claimError);
        return;
    }
    if (self.timer) { dispatch_source_cancel(self.timer); self.timer = nil; }
    self.phase = VPHomePodWelcomeTone;
    [self record:@"TonePlaying" error:nil];
    [self.flourish setLocalSessionActive:YES];
    __weak VPHomePodWelcome *weakSelf = self;
    [[self.board uiTonePlaybackManager] play:1 completion:^(NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            VPHomePodWelcome *welcome = weakSelf;
            if (!welcome || welcome.phase != VPHomePodWelcomeTone) return;
            [welcome.flourish setLocalSessionActive:NO];
            welcome.flourish = nil;
            if (error) { [welcome stop:@"ToneFailed" error:error]; return; }
            welcome.phase = VPHomePodWelcomePause;
            [welcome record:@"ToneFinished" error:nil];
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 650 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
                [weakSelf speak];
            });
        });
    }];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 30 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        VPHomePodWelcome *welcome = weakSelf;
        if (welcome && welcome.phase == VPHomePodWelcomeTone) [welcome stop:@"ToneTimedOut" error:nil];
    });
}

- (void)speak {
    if (self.phase != VPHomePodWelcomePause) return;
    if (![self enabled]) { [self stop:@"Cancelled" error:nil]; return; }
    if (![self.siri siriEnabled] || ![VPWelcomeSessionStateName([self.siri currentSessionState]) isEqual:@"idle"]) {
        [self stop:@"SpeechUnavailable" error:nil];
        return;
    }
    self.phase = VPHomePodWelcomeSpeech;
    [self record:@"SpeechRequested" error:nil];
    __weak VPHomePodWelcome *weakSelf = self;
    [self.siri say:VPHomePodWelcomePhrase completion:^(NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            VPHomePodWelcome *welcome = weakSelf;
            if (!welcome || welcome.phase != VPHomePodWelcomeSpeech) return;
            if (error) { [welcome stop:@"SpeechFailed" error:error]; return; }
            // SiriVOX's synthesis finalizer returns its NSError here. The API
            // omits the result type (including cancellation), so record that
            // exact boundary rather than claiming the sentence was audible.
            [welcome stop:@"SpeechFinalized" error:nil];
        });
    }];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 90 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        VPHomePodWelcome *welcome = weakSelf;
        if (welcome && welcome.phase == VPHomePodWelcomeSpeech) [welcome stop:@"SpeechTimedOut" error:nil];
    });
}

@end

#if !defined(VP_HOMEPOD_DISPLAY_TESTING) && !defined(VP_HOMEPOD_WELCOME_TESTING)
static VPHomePodWelcome *VPWelcomeController;
static void (*VPWelcomeOriginalApplicationsReady)(id, SEL);

static NSString *VPWelcomeGuestIdentity(void) {
    void *gestalt = dlopen("/usr/lib/libMobileGestalt.dylib", RTLD_NOW);
    CFTypeRef (*copyAnswer)(CFStringRef) = gestalt ? dlsym(gestalt, "MGCopyAnswer") : NULL;
    id identity = copyAnswer ? CFBridgingRelease(copyAnswer(CFSTR("UniqueDeviceID"))) : nil;
    // Scope the durable claim to this guest, including when its Data volume was
    // cloned from a previously booted template. Read identity, never override it.
    if (![identity isKindOfClass:NSString.class] || [identity length] == 0 || [identity length] > 128) return nil;
    NSCharacterSet *invalid = [[NSCharacterSet characterSetWithCharactersInString:@"0123456789abcdefABCDEF-"] invertedSet];
    return [identity rangeOfCharacterFromSet:invalid].location == NSNotFound ? [identity lowercaseString] : nil;
}

static void VPWelcomeApplicationsReady(id board, SEL selector) {
    VPWelcomeOriginalApplicationsReady(board, selector);
    // Observe Apple's constructed instance. Never force sharedInstance from a
    // dylib constructor, which could initialize SoundBoard before its OS setup.
    dispatch_async(dispatch_get_main_queue(), ^{
        if (VPWelcomeController) return;
        NSString *identity = VPWelcomeGuestIdentity();
        if (!identity) { NSLog(@"vphone HomePod welcome: stable guest identity unavailable"); return; }
        NSString *directory = [@"/var/mobile/Library/Application Support/vphone/HomePodWelcome" stringByAppendingPathComponent:identity];
        VPWelcomeController = [[VPHomePodWelcome alloc] initWithBoard:board
            directory:directory policy:@"/usr/share/vphone/HomePodWelcome.plist"];
        dispatch_source_t timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
        VPWelcomeController.timer = timer;
        dispatch_source_set_timer(timer, DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC, 250 * NSEC_PER_MSEC);
        dispatch_source_set_event_handler(timer, ^{ [VPWelcomeController poll]; });
        dispatch_resume(timer);
    });
}

void VPHomePodWelcomeInstall(void) {
    static BOOL installed;
    if (installed) return;
    NSDictionary *policy = [NSDictionary dictionaryWithContentsOfFile:@"/usr/share/vphone/HomePodWelcome.plist"];
    if (![policy[@"Enabled"] isEqual:@YES]) return;
    VPWelcomeSessionStateName = dlsym(RTLD_DEFAULT, "SVXSessionStateGetName");
    if (!VPWelcomeSessionStateName) {
        NSLog(@"vphone HomePod welcome: native Siri state API unavailable");
        return;
    }
    Class board = NSClassFromString(@"SBSoundBoard");
    SEL selector = NSSelectorFromString(@"_applicationsModuleInitComplete");
    Method method = class_getInstanceMethod(board, selector);
    NSMethodSignature *signature = method ? [NSMethodSignature signatureWithObjCTypes:method_getTypeEncoding(method)] : nil;
    if (!signature || signature.numberOfArguments != 2 || strcmp(signature.methodReturnType, @encode(void))) {
        NSLog(@"vphone HomePod welcome: native lifecycle ABI unavailable");
        return;
    }
    VPWelcomeOriginalApplicationsReady = (void *)method_setImplementation(method, (IMP)VPWelcomeApplicationsReady);
    installed = YES;
}
#endif

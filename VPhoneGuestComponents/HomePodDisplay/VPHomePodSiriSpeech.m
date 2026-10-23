#import "VPHomePodSiriSpeech.h"
#import <objc/runtime.h>
#include <mach/mach_time.h>
#ifdef VP_HOMEPOD_SIRI_SPEECH_TESTING
// Frozen public AVFAudio SDK values for the macOS-only native harness.
enum { AVAudioSessionCategoryOptionMixWithOthers = 0x1,
       AVAudioSessionCategoryOptionDuckOthers = 0x2,
       AVAudioSessionSetActiveOptionNotifyOthersOnDeactivation = 0x1 };
#else
#import <AVFAudio/AVAudioSession.h>
#endif

@protocol VPHomePodSiriNative
@optional
- (id)initWithCategory:(NSString *)category categoryOptions:(NSUInteger)options;
+ (id)auxiliaryAudioSessionManagerWithConfiguration:(id)configuration name:(NSString *)name;
- (BOOL)activateAndReturnError:(NSError **)error;
- (BOOL)deactivateWithOptions:(NSUInteger)options deactivateImmediately:(BOOL)immediately error:(NSError **)error;
- (id)audioSession;
- (uint32_t)opaqueSessionID;
- (id)initWithPriority:(NSInteger)priority options:(NSUInteger)options speakableText:(NSString *)text
    speakableContext:(id)context localizationKey:(id)key presynthesizedAudio:(id)audio streamID:(id)stream;
+ (id)newWithBuilder:(void (^)(id))builder;
- (void)setTimestamp:(uint64_t)timestamp;
- (void)setType:(NSInteger)type;
- (void)setSpeechSynthesisRequest:(id)request;
- (void)setAudioSessionID:(uint32_t)sessionID;
- (id)siriClientInterface;
- (id)activationService;
- (void)activateWithSystemEvent:(id)event userInfo:(NSDictionary *)info completion:(void (^)(NSError *))completion;
@end

static Class VPSiriClass(NSString *name) {
#ifdef VP_HOMEPOD_SIRI_SPEECH_TESTING
    if ([name isEqualToString:@"AVAudioSession"]) return NSClassFromString(@"VPSiriMockAudioSession");
#endif
    return NSClassFromString(name);
}

static NSString *const VPSiriSpeechPolicy = @"/usr/share/vphone/HomePodSiriSpeech.plist";
static void (*VPSiriOriginalSay)(id, SEL, NSString *, void (^)(NSError *));

static BOOL VPSiriSpeechEnabled(void) {
#ifdef VP_HOMEPOD_SIRI_SPEECH_TESTING
    extern BOOL VPSiriSpeechTestEnabled;
    return VPSiriSpeechTestEnabled;
#else
    return [NSProcessInfo.processInfo.processName isEqualToString:@"SoundBoard"] &&
        [[NSDictionary dictionaryWithContentsOfFile:VPSiriSpeechPolicy][@"Enabled"] isEqual:@YES];
#endif
}

static BOOL VPSiriSignature(Class cls, BOOL classMethod, SEL selector, const char *result,
                            NSArray<NSString *> *arguments) {
    Method method = classMethod ? class_getClassMethod(cls, selector) : class_getInstanceMethod(cls, selector);
    if (!method) return NO;
    NSMethodSignature *signature = [NSMethodSignature signatureWithObjCTypes:method_getTypeEncoding(method)];
    if (signature.numberOfArguments != arguments.count + 2 || strcmp(signature.methodReturnType, result)) return NO;
    for (NSUInteger i = 0; i < arguments.count; i++) {
        if (strcmp([signature getArgumentTypeAtIndex:i + 2], arguments[i].UTF8String)) return NO;
    }
    return YES;
}

static BOOL VPSiriSpeechABI(void) {
    return VPSiriSignature(VPSiriClass(@"SBSiriManager"), NO, NSSelectorFromString(@"say:completion:"), "v", @[@"@", @"@?"]) &&
        VPSiriSignature(VPSiriClass(@"SBSiriManager"), NO, @selector(siriClientInterface), "@", @[]) &&
        VPSiriSignature(VPSiriClass(@"SVXClientServiceConnection"), NO, @selector(activationService), "@", @[]) &&
        VPSiriSignature(VPSiriClass(@"SVXClientActivationService"), NO, @selector(activateWithSystemEvent:userInfo:completion:), "v", @[@"@", @"@", @"@?"]) &&
        VPSiriSignature(VPSiriClass(@"SBAudioSessionConfiguration"), NO, @selector(initWithCategory:categoryOptions:), "@", @[@"@", @"Q"]) &&
        VPSiriSignature(VPSiriClass(@"SBAudioSessionManager"), YES, @selector(auxiliaryAudioSessionManagerWithConfiguration:name:), "@", @[@"@", @"@"]) &&
        VPSiriSignature(VPSiriClass(@"SBAudioSessionManager"), NO, @selector(activateAndReturnError:), "B", @[@"^@"]) &&
        VPSiriSignature(VPSiriClass(@"SBAudioSessionManager"), NO, @selector(deactivateWithOptions:deactivateImmediately:error:), "B", @[@"Q", @"B", @"^@"]) &&
        VPSiriSignature(VPSiriClass(@"SBAudioSessionManager"), NO, @selector(audioSession), "@", @[]) &&
        VPSiriSignature(VPSiriClass(@"AVAudioSession"), NO, @selector(opaqueSessionID), "I", @[]) &&
        VPSiriSignature(VPSiriClass(@"SVXSpeechSynthesisRequest"), NO, @selector(initWithPriority:options:speakableText:speakableContext:localizationKey:presynthesizedAudio:streamID:), "@", @[@"q", @"Q", @"@", @"@", @"@", @"@", @"@"]) &&
        VPSiriSignature(VPSiriClass(@"SVXSystemEvent"), YES, @selector(newWithBuilder:), "@", @[@"@?"]) &&
        VPSiriSignature(VPSiriClass(@"_SVXSystemEventMutation"), NO, @selector(setTimestamp:), "v", @[@"Q"]) &&
        VPSiriSignature(VPSiriClass(@"_SVXSystemEventMutation"), NO, @selector(setType:), "v", @[@"q"]) &&
        VPSiriSignature(VPSiriClass(@"_SVXSystemEventMutation"), NO, @selector(setSpeechSynthesisRequest:), "v", @[@"@"]) &&
        VPSiriSignature(VPSiriClass(@"_SVXSystemEventMutation"), NO, @selector(setAudioSessionID:), "v", @[@"I"]);
}

static NSError *VPSiriSpeechError(NSString *message) {
    return [NSError errorWithDomain:@"com.vphone.homepod.siri-speech" code:1
                           userInfo:@{NSLocalizedDescriptionKey: message}];
}

// The completion block owns this object through native synthesis finalization.
// Keep a separate auxiliary session; never change AVAudioSession.sharedInstance.
@interface VPHomePodSiriSpeechRequest : NSObject
@property (strong) id<VPHomePodSiriNative> audioManager;
@property (copy) void (^completion)(NSError *);
@property BOOL finished;
@property BOOL active;
- (void)finish:(NSError *)error;
@end

@implementation VPHomePodSiriSpeechRequest
- (void)finish:(NSError *)error {
    @synchronized (self) {
        if (self.finished) return;
        self.finished = YES;
    }
    if (self.active) {
        NSError *cleanupError = nil;
        if (![self.audioManager deactivateWithOptions:AVAudioSessionSetActiveOptionNotifyOthersOnDeactivation
                               deactivateImmediately:YES error:&cleanupError]) {
            NSLog(@"vphone HomePod Siri speech: auxiliary session cleanup failed: %@", cleanupError);
        }
        self.active = NO;
    }
    self.audioManager = nil;
    void (^completion)(NSError *) = self.completion;
    self.completion = nil;
    if (completion) completion(error);
}
@end

static void VPSiriSpeechSay(id<VPHomePodSiriNative> manager, SEL selector, NSString *text,
                           void (^completion)(NSError *)) {
    if (!VPSiriSpeechEnabled()) {
        VPSiriOriginalSay(manager, selector, text, completion);
        return;
    }
    VPHomePodSiriSpeechRequest *lifetime = [VPHomePodSiriSpeechRequest new];
    lifetime.completion = completion;
    @try {
        id<VPHomePodSiriNative> configuration = [(id<VPHomePodSiriNative>)[VPSiriClass(@"SBAudioSessionConfiguration") alloc]
            initWithCategory:@"AVAudioSessionCategoryPlayback"
            categoryOptions:AVAudioSessionCategoryOptionMixWithOthers | AVAudioSessionCategoryOptionDuckOthers];
        // A nonmixing playback session interrupts tvairplayd and makes the
        // sender abandon this AirPlay receiver. Duck its existing session for
        // speech, then notify it on deactivation so music and cap can continue.
        if (!configuration) {
            [lifetime finish:VPSiriSpeechError(@"Unable to create auxiliary playback configuration")];
            return;
        }
        lifetime.audioManager = [(id<VPHomePodSiriNative>)VPSiriClass(@"SBAudioSessionManager")
            auxiliaryAudioSessionManagerWithConfiguration:configuration name:@"vphone Siri speech"];
        NSError *activationError = nil;
        if (!lifetime.audioManager || ![lifetime.audioManager activateAndReturnError:&activationError]) {
            [lifetime finish:activationError ?: VPSiriSpeechError(@"Unable to activate auxiliary playback session")];
            return;
        }
        lifetime.active = YES;
        uint32_t sessionID = [[lifetime.audioManager audioSession] opaqueSessionID];
        if (!sessionID) {
            [lifetime finish:VPSiriSpeechError(@"Auxiliary playback session has no session ID")];
            return;
        }
        // SoundBoard 24J361 uses priority 2, options 0 and event type 13.
        // SVXSession's native External path accepts this real session ID,
        // avoiding its own microphone/record-route activation while retaining
        // normal Siri activation, HPASiri rendering and synthesis finalization.
        id request = [(id<VPHomePodSiriNative>)[VPSiriClass(@"SVXSpeechSynthesisRequest") alloc]
            initWithPriority:2 options:0 speakableText:text speakableContext:nil localizationKey:nil
            presynthesizedAudio:nil streamID:nil];
        id event = [(id<VPHomePodSiriNative>)VPSiriClass(@"SVXSystemEvent") newWithBuilder:^(id<VPHomePodSiriNative> builder) {
            [builder setTimestamp:mach_absolute_time()];
            [builder setType:13];
            [builder setSpeechSynthesisRequest:request];
            [builder setAudioSessionID:sessionID];
        }];
        id<VPHomePodSiriNative> service = [[manager siriClientInterface] activationService];
        if (!request || !event || !service) {
            [lifetime finish:VPSiriSpeechError(@"Native Siri speech service is unavailable")];
            return;
        }
        [service activateWithSystemEvent:event userInfo:@{} completion:^(NSError *error) {
            // SVXSession passes result.error here after finalization. Its
            // separate postActivationHandler is invoked before enqueueing.
            [lifetime finish:error];
        }];
    } @catch (NSException *exception) {
        [lifetime finish:VPSiriSpeechError(exception.reason ?: @"Native Siri speech request failed")];
    }
}

BOOL VPHomePodSiriSpeechInstall(void) {
    static BOOL installed;
    if (!VPSiriSpeechEnabled()) return NO;
    if (!VPSiriSpeechABI()) {
        NSLog(@"vphone HomePod Siri speech: native playback/event ABI unavailable");
        return NO;
    }
    if (installed) return YES;
    Method method = class_getInstanceMethod(VPSiriClass(@"SBSiriManager"), NSSelectorFromString(@"say:completion:"));
    VPSiriOriginalSay = (void *)method_setImplementation(method, (IMP)VPSiriSpeechSay);
    installed = YES;
    return YES;
}

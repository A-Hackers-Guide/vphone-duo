#define VP_HOMEPOD_SIRI_SPEECH_TESTING 1
#import "../HomePodDisplay/VPHomePodSiriSpeech.m"
#include <assert.h>

BOOL VPSiriSpeechTestEnabled;
static NSUInteger sharedSessionRequests, originalRequests, auxiliaryRequests;
static BOOL failActivation, zeroSessionID;
static NSError *nativeError;

@interface VPSiriMockAudioSession : NSObject
@property uint32_t opaqueSessionID;
+ (id)sharedInstance;
@end
@implementation VPSiriMockAudioSession
+ (id)sharedInstance { sharedSessionRequests++; return [self new]; }
@end

@interface SBAudioSessionConfiguration : NSObject
@property (copy) NSString *category;
@property NSUInteger options;
- (id)initWithCategory:(NSString *)category categoryOptions:(NSUInteger)options;
@end
@implementation SBAudioSessionConfiguration
- (id)initWithCategory:(NSString *)category categoryOptions:(NSUInteger)options {
    if ((self = [super init])) { _category = category; _options = options; }
    return self;
}
@end

@interface SBAudioSessionManager : NSObject
@property (strong) VPSiriMockAudioSession *audioSession;
@property (strong) SBAudioSessionConfiguration *configuration;
@property NSUInteger activations, deactivations;
+ (id)auxiliaryAudioSessionManagerWithConfiguration:(id)configuration name:(NSString *)name;
- (BOOL)activateAndReturnError:(NSError **)error;
- (BOOL)deactivateWithOptions:(NSUInteger)options deactivateImmediately:(BOOL)immediately error:(NSError **)error;
@end
static __weak SBAudioSessionManager *lastAuxiliary;
@implementation SBAudioSessionManager
+ (id)auxiliaryAudioSessionManagerWithConfiguration:(id)configuration name:(NSString *)name {
    assert([name isEqual:@"vphone Siri speech"]);
    auxiliaryRequests++;
    SBAudioSessionManager *manager = [self new];
    manager.configuration = configuration;
    manager.audioSession = [VPSiriMockAudioSession new];
    manager.audioSession.opaqueSessionID = zeroSessionID ? 0 : 47;
    lastAuxiliary = manager;
    return manager;
}
- (BOOL)activateAndReturnError:(NSError **)error {
    self.activations++;
    if (failActivation) { if (error) *error = nativeError; return NO; }
    return YES;
}
- (BOOL)deactivateWithOptions:(NSUInteger)options deactivateImmediately:(BOOL)immediately error:(NSError **)error {
    assert(options == 1 && immediately);
    (void)error;
    self.deactivations++;
    return YES;
}
@end

@interface SVXSpeechSynthesisRequest : NSObject
@property NSInteger priority;
@property NSUInteger options;
@property (copy) NSString *speakableText;
- (id)initWithPriority:(NSInteger)priority options:(NSUInteger)options speakableText:(NSString *)text
    speakableContext:(id)context localizationKey:(id)key presynthesizedAudio:(id)audio streamID:(id)stream;
@end
@implementation SVXSpeechSynthesisRequest
- (id)initWithPriority:(NSInteger)priority options:(NSUInteger)options speakableText:(NSString *)text
    speakableContext:(id)context localizationKey:(id)key presynthesizedAudio:(id)audio streamID:(id)stream {
    assert(!context && !key && !audio && !stream);
    if ((self = [super init])) { _priority = priority; _options = options; _speakableText = text; }
    return self;
}
@end

@interface _SVXSystemEventMutation : NSObject
@property uint64_t timestamp;
@property NSInteger type;
@property (strong) SVXSpeechSynthesisRequest *speechSynthesisRequest;
@property uint32_t audioSessionID;
@end
@implementation _SVXSystemEventMutation
@end
@interface SVXSystemEvent : _SVXSystemEventMutation
+ (id)newWithBuilder:(void (^)(id))builder;
@end
@implementation SVXSystemEvent
+ (id)newWithBuilder:(void (^)(id))builder { id event = [self new]; builder(event); return event; }
@end

@interface SVXClientActivationService : NSObject
@property (strong) SVXSystemEvent *event;
@property (copy) void (^completion)(NSError *);
- (void)activateWithSystemEvent:(id)event userInfo:(NSDictionary *)info completion:(void (^)(NSError *))completion;
@end
@implementation SVXClientActivationService
- (void)activateWithSystemEvent:(id)event userInfo:(NSDictionary *)info completion:(void (^)(NSError *))completion {
    assert(info.count == 0);
    self.event = event; self.completion = completion;
}
@end
@interface SVXClientServiceConnection : NSObject
@property (strong) id activationService;
@end
@implementation SVXClientServiceConnection
@end
@interface SBSiriManager : NSObject
@property (strong) id siriClientInterface;
- (void)say:(NSString *)text completion:(void (^)(NSError *))completion;
@end
@implementation SBSiriManager
- (void)say:(NSString *)text completion:(void (^)(NSError *))completion {
    (void)text;
    originalRequests++;
    if (completion) completion(nil);
}
@end

int main(void) {
    @autoreleasepool {
        nativeError = [NSError errorWithDomain:@"NativeFailure" code:42 userInfo:nil];
        assert(VPSiriSpeechABI());
        assert(!VPSiriSignature(VPSiriMockAudioSession.class, NO, @selector(opaqueSessionID), "Q", @[]));
        assert(!VPSiriSignature(SBSiriManager.class, NO, @selector(siriClientInterface), "@", @[@"I"]));
        assert(!VPSiriSignature(Nil, NO, @selector(siriClientInterface), "@", @[]));
        assert(!VPHomePodSiriSpeechInstall());
        SBSiriManager *siri = [SBSiriManager new];
        SVXClientServiceConnection *client = [SVXClientServiceConnection new];
        SVXClientActivationService *service = [SVXClientActivationService new];
        client.activationService = service; siri.siriClientInterface = client;
        VPSiriSpeechTestEnabled = YES;
        assert(VPHomePodSiriSpeechInstall());
        assert(VPHomePodSiriSpeechInstall());
        __block NSUInteger completions = 0;
        __block NSError *received = nil;
        @autoreleasepool {
            [siri say:@"Native Siri phrase" completion:^(NSError *error) { completions++; received = error; }];
        }
        SBAudioSessionManager *aux = lastAuxiliary;
        assert(aux && aux.activations == 1 && aux.deactivations == 0 && completions == 0);
        assert([aux.configuration.category isEqual:@"AVAudioSessionCategoryPlayback"] && aux.configuration.options == 3);
        assert(service.event.type == 13 && service.event.timestamp && service.event.audioSessionID == 47);
        assert(service.event.speechSynthesisRequest.priority == 2 && service.event.speechSynthesisRequest.options == 0);
        assert([service.event.speechSynthesisRequest.speakableText isEqual:@"Native Siri phrase"]);
        // Submission does not release the auxiliary session. The native final
        // callback, including a failure, is the lifetime boundary.
        service.completion(nativeError);
        assert(completions == 1 && received == nativeError && aux.deactivations == 1);
        service.completion(nil);
        assert(completions == 1 && aux.deactivations == 1);
        service.completion = nil; aux = nil;
        assert(!lastAuxiliary);
        [siri say:@"Second" completion:^(NSError *error) { completions++; received = error; }];
        aux = lastAuxiliary;
        assert(aux.deactivations == 0);
        service.completion(nil);
        assert(completions == 2 && received == nil && aux.deactivations == 1);
        service.completion = nil;
        failActivation = YES;
        [siri say:@"Failure" completion:^(NSError *error) { completions++; received = error; }];
        assert(completions == 3 && received == nativeError && lastAuxiliary.activations == 1 && lastAuxiliary.deactivations == 0);
        failActivation = NO; zeroSessionID = YES;
        [siri say:@"Missing ID" completion:^(NSError *error) { completions++; received = error; }];
        assert(completions == 4 && received && lastAuxiliary.deactivations == 1);
        zeroSessionID = NO;
        client.activationService = nil;
        [siri say:@"Disconnected" completion:^(NSError *error) { completions++; received = error; }];
        assert(completions == 5 && received && lastAuxiliary.deactivations == 1);
        NSUInteger beforeDisabled = auxiliaryRequests;
        VPSiriSpeechTestEnabled = NO;
        assert(!VPHomePodSiriSpeechInstall());
        [siri say:@"Original" completion:^(NSError *error) { completions++; received = error; }];
        assert(originalRequests == 1 && auxiliaryRequests == beforeDisabled && received == nil);
        assert(sharedSessionRequests == 0);
        puts("HomePod Siri speech tests passed");
    }
    return 0;
}

#define VP_HOMEPOD_WELCOME_TESTING 1
#import "../HomePodDisplay/VPHomePodWelcome.m"
#include <assert.h>

static BOOL needsSetup;
@interface SBSetupController : NSObject
+ (BOOL)deviceNeedsSetup;
@end
@implementation SBSetupController
+ (BOOL)deviceNeedsSetup { return needsSetup; }
@end

@interface WelcomeDisplay : NSObject
@property BOOL startupComplete;
@property BOOL drawing;
- (NSDictionary *)diagnosticsInfo;
@end
@implementation WelcomeDisplay
- (NSDictionary *)diagnosticsInfo { return @{@"DrawingEnabled": @(self.drawing)}; }
@end

@interface WelcomeActivity : NSObject
@property (nonatomic) BOOL localSessionActive;
@property BOOL remoteSessionActive;
@property BOOL siriUIEnabled;
@property (copy) NSString *activityName;
@property NSUInteger stops;
- (void)endLocalSessionActivity;
@end
@implementation WelcomeActivity
@synthesize localSessionActive = _localSessionActive;
- (void)setLocalSessionActive:(BOOL)active {
    if (_localSessionActive == active) return;
    _localSessionActive = active;
    if (!active) [self endLocalSessionActivity];
}
// Native Identify only stops its tone/animation in this subclass callback.
// The coordinated setter owns the active flag and foreground dismissal.
- (void)endLocalSessionActivity { self.stops++; }
@end

@interface WelcomeActivities : NSObject
@property (strong) WelcomeActivity *identify;
@property (strong) WelcomeActivity *siri;
@property (strong) id foregroundedActivity;
@property NSUInteger activeMediaCount;
- (id)activityWithName:(NSString *)name;
@end
@implementation WelcomeActivities
- (id)activityWithName:(NSString *)name {
    return [name isEqual:@"Identify"] ? self.identify : [name isEqual:@"Siri"] ? self.siri : nil;
}
@end

@interface WelcomeSiri : NSObject
@property BOOL siriEnabled;
@property NSInteger currentSessionState;
@property (copy) NSString *phrase;
@property (copy) void (^completion)(NSError *);
@property NSUInteger requests;
- (void)say:(NSString *)text completion:(void (^)(NSError *))completion;
@end
@implementation WelcomeSiri
- (void)say:(NSString *)text completion:(void (^)(NSError *))completion {
    self.phrase = text; self.completion = completion; self.requests++;
}
@end

@interface WelcomeTone : NSObject
@property uint32_t tone;
@property NSUInteger requests;
@property (copy) void (^completion)(NSError *);
- (void)play:(uint32_t)tone completion:(void (^)(NSError *))completion;
@end
@implementation WelcomeTone
- (void)play:(uint32_t)tone completion:(void (^)(NSError *))completion {
    self.tone = tone; self.completion = completion; self.requests++;
}
@end
@interface WrongToneABI : NSObject
- (void)play:(uint64_t)tone completion:(void (^)(NSError *))completion;
@end
@implementation WrongToneABI
- (void)play:(uint64_t)tone completion:(void (^)(NSError *))completion { (void)tone; (void)completion; abort(); }
@end

@interface WelcomeBoard : NSObject
@property (strong) WelcomeActivities *activityManager;
@property (strong) WelcomeDisplay *displayService;
@property (strong) WelcomeSiri *siriManager;
@property (strong) id uiTonePlaybackManager;
@end
@implementation WelcomeBoard
@end

static NSString *root;
static NSString *policy;
static WelcomeBoard *board;
static WelcomeTone *tone;
static NSString *directory;

static NSString *stateName(NSInteger state) { return state == 1 ? @"idle" : @"presenting"; }

static VPHomePodWelcome *fresh(void) {
    directory = [root stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
    needsSetup = NO;
    board = WelcomeBoard.new;
    board.activityManager = WelcomeActivities.new;
    board.activityManager.identify = WelcomeActivity.new;
    board.activityManager.siri = WelcomeActivity.new;
    board.activityManager.siri.siriUIEnabled = YES;
    board.displayService = WelcomeDisplay.new;
    board.displayService.startupComplete = YES; board.displayService.drawing = YES;
    board.siriManager = WelcomeSiri.new; board.siriManager.siriEnabled = YES; board.siriManager.currentSessionState = 1;
    tone = WelcomeTone.new; board.uiTonePlaybackManager = tone;
    assert([@{@"Enabled": @YES} writeToFile:policy atomically:YES]);
    return [[VPHomePodWelcome alloc] initWithBoard:board directory:directory policy:policy];
}

static NSDictionary *status(void) {
    return [NSDictionary dictionaryWithContentsOfFile:[directory stringByAppendingPathComponent:@"Status.plist"]];
}
static void spin(NSTimeInterval duration) {
    NSDate *until = [NSDate dateWithTimeIntervalSinceNow:duration];
    while (until.timeIntervalSinceNow > 0) [NSRunLoop.mainRunLoop runMode:NSDefaultRunLoopMode beforeDate:until];
}

int main(void) { @autoreleasepool {
    VPWelcomeSessionStateName = stateName;
    // Independent donor metadata: SBUITonePlaybackManager on 24J361 is UInt32,
    // v28@0:8I16@?20. A UInt64 mock used to agree with a wrong production guard
    // and concealed that every real guest would wait for readiness forever.
    NSMethodSignature *donorTone = [NSMethodSignature signatureWithObjCTypes:"v28@0:8I16@?20"];
    NSMethodSignature *mockTone = [WelcomeTone instanceMethodSignatureForSelector:@selector(play:completion:)];
    assert(strcmp(mockTone.methodReturnType, donorTone.methodReturnType) == 0);
    assert(mockTone.numberOfArguments == donorTone.numberOfArguments);
    for (NSUInteger i = 0; i < donorTone.numberOfArguments; i++) {
        assert(strcmp([mockTone getArgumentTypeAtIndex:i], [donorTone getArgumentTypeAtIndex:i]) == 0);
    }
    root = [NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
    assert([NSFileManager.defaultManager createDirectoryAtPath:root withIntermediateDirectories:YES attributes:nil error:NULL]);
    policy = [root stringByAppendingPathComponent:@"Policy.plist"];

    // Readiness can arrive in either order. Waiting never consumes the claim.
    VPHomePodWelcome *welcome = fresh();
    needsSetup = YES; [welcome poll]; assert(tone.requests == 0);
    needsSetup = NO; board.displayService.startupComplete = NO; [welcome poll]; assert(tone.requests == 0);
    board.displayService.startupComplete = YES; board.displayService.drawing = NO; [welcome poll]; assert(tone.requests == 0);
    board.displayService.drawing = YES; board.siriManager.siriEnabled = NO; [welcome poll]; assert(tone.requests == 0);
    board.siriManager.siriEnabled = YES; board.siriManager.currentSessionState = 4; [welcome poll]; assert(tone.requests == 0);
    board.siriManager.currentSessionState = 1; board.activityManager.siri.siriUIEnabled = NO; [welcome poll]; assert(tone.requests == 0);
    board.activityManager.siri.siriUIEnabled = YES;
    WelcomeActivity *foreground = WelcomeActivity.new; foreground.activityName = @"HPSetup";
    board.activityManager.foregroundedActivity = foreground; [welcome poll]; assert(tone.requests == 0);
    foreground.activityName = @"NowPlayingCap"; board.activityManager.activeMediaCount = 1; [welcome poll]; assert(tone.requests == 0);
    assert(![NSFileManager.defaultManager fileExistsAtPath:directory]);
    board.activityManager.activeMediaCount = 0; [welcome poll]; assert(tone.requests == 1 && tone.tone == 1);
    assert(board.activityManager.identify.localSessionActive);
    assert(board.siriManager.requests == 0);
    [welcome poll]; assert(tone.requests == 1);
    tone.completion(nil); spin(0.1);
    assert(!board.activityManager.identify.localSessionActive && board.activityManager.identify.stops == 1);
    assert(board.siriManager.requests == 0); // Wait for tone completion, then the pause.
    spin(0.7);
    assert(board.siriManager.requests == 1);
    assert([board.siriManager.phrase isEqual:@"Hi, I'm Siri. It sure is great to be running in a virtual machine!"]);
    board.siriManager.completion(nil); spin(0.05);
    assert([status()[@"State"] isEqual:@"SpeechFinalized"]);
    VPHomePodWelcome *restart = [[VPHomePodWelcome alloc] initWithBoard:board directory:directory policy:policy];
    [restart poll]; assert(tone.requests == 1 && board.siriManager.requests == 1);

    // Native tone failure releases only our flourish and prevents speech/replay.
    welcome = fresh(); [welcome poll];
    NSError *failure = [NSError errorWithDomain:@"NativeTone" code:42 userInfo:nil];
    tone.completion(failure); spin(0.05);
    assert([status()[@"State"] isEqual:@"ToneFailed"] && board.siriManager.requests == 0);
    assert([status()[@"ErrorDomain"] isEqual:@"NativeTone"]);
    assert(!board.activityManager.identify.localSessionActive);

    // Opt-out before readiness leaves Data untouched; during the pause it cancels
    // speech while retaining the already-consumed claim.
    welcome = fresh(); assert([@{@"Enabled": @NO} writeToFile:policy atomically:YES]);
    [welcome poll]; assert(tone.requests == 0 && ![NSFileManager.defaultManager fileExistsAtPath:directory]);
    welcome = fresh(); [welcome poll]; tone.completion(nil); spin(0.1);
    assert([@{@"Enabled": @NO} writeToFile:policy atomically:YES]); spin(0.7);
    assert(board.siriManager.requests == 0 && [status()[@"State"] isEqual:@"Cancelled"]);
    assert([NSFileManager.defaultManager fileExistsAtPath:[directory stringByAppendingPathComponent:@"Claim.plist"]]);

    welcome = fresh(); [welcome poll]; tone.completion(nil); spin(0.8);
    board.siriManager.completion([NSError errorWithDomain:@"NativeSiri" code:221 userInfo:nil]); spin(0.05);
    assert([status()[@"State"] isEqual:@"SpeechFailed"]);
    assert([status()[@"ErrorCode"] isEqual:@221]);
    board.siriManager.completion(nil); spin(0.05);
    assert([status()[@"State"] isEqual:@"SpeechFailed"]); // Late callbacks cannot erase failure.

    // A changed donor ABI or unavailable Data volume fails before side effects.
    welcome = fresh(); board.uiTonePlaybackManager = WrongToneABI.new; [welcome poll]; assert(tone.requests == 0);
    assert(![NSFileManager.defaultManager fileExistsAtPath:directory]);
    welcome = fresh(); assert([@"not a directory" writeToFile:directory atomically:YES encoding:NSUTF8StringEncoding error:NULL]);
    [welcome poll]; assert(tone.requests == 0 && !board.activityManager.identify.localSessionActive);

    assert([NSFileManager.defaultManager removeItemAtPath:root error:NULL]);
    puts("HomePod welcome ordering, readiness, cancellation and native failure tests passed");
} return 0; }

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Guest Data state for one welcome. A successful claim must precede every
/// audiovisual side effect; progress updates never replace or remove it.
@interface VPHomePodWelcomeState : NSObject
- (instancetype)initWithDirectory:(NSString *)directory NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

/// YES only after creating and durably recording a new exclusive claim.
/// An existing claim returns NO without an error, regardless of its contents.
/// I/O and symlink failures return NO with an error and never permit playback.
- (BOOL)claimWithError:(NSError * _Nullable * _Nullable)error;

/// Replaces only Status.plist. Fields must be property-list values; State and
/// Updated are reserved and always supplied by this method.
- (BOOL)writeStatus:(NSString *)status fields:(NSDictionary *)fields error:(NSError * _Nullable * _Nullable)error;
@end

NS_ASSUME_NONNULL_END

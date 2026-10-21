#pragma once
#import <Foundation/Foundation.h>

// Apple's HIDEventAccessors.h and HIDEventAccessors_Internal.h. Runtime lookup
// keeps the guest library independent of private SDK stubs.
@protocol VPhoneAccelerometerHIDEvent <NSObject>
+ (id)accelerometerEvent:(uint64_t)timestamp x:(double)x y:(double)y z:(double)z options:(uint32_t)options;
- (void)setAccelerometerSequence:(uint32_t)sequence;
@property (readonly) uint32_t accelerometerSequence;
@property (readonly) double accelerometerX;
@property (readonly) double accelerometerY;
@property (readonly) double accelerometerZ;
@property (readonly) uint64_t timestamp;
@end

@protocol VPhoneAccelerometerHIDService <NSObject>
@property (weak) id delegate;
@property (readonly) uint64_t serviceID;
- (void)setDispatchQueue:(dispatch_queue_t)queue;
- (void)setCancelHandler:(dispatch_block_t)handler;
- (void)activate;
- (void)cancel;
- (BOOL)dispatchEvent:(id)event;
@end

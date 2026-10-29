#pragma once
#import <Foundation/Foundation.h>
#include <math.h>

// One dictionary per update, written by vphoned and read by the provider in
// backboardd, as for the gyroscope. The angle is the host's hinge slider in
// degrees: 0 is closed, 180 is open flat. It is published unrounded.
#define VP_HINGE_DOMAIN "com.apple.backboardd"
#define VP_HINGE_CONFIGURATION "VPhoneHingeConfiguration"
#define VP_HINGE_STATUS "VPhoneHingeStatus"
#define VP_HINGE_NOTIFICATION "com.vphone.motion.hinge.changed"

// IOHIDEventCreateHingeAngleEvent(allocator, timestamp, angle, mechanical
// angle, velocity, options) builds event type 0x2C (kIOHIDEventTypeHingeAngle)
// in iOS 27's IOKit; the state is a byte set afterwards. Checked against
// 24B91020's IOKit and CoreMotion's CLLidAngleNotifier assertion.
#define VP_HINGE_EVENT_TYPE 0x2C
#define VP_HINGE_ANGLE_MAX 180.0
#define VP_HINGE_VELOCITY_MAX 3600.0

typedef struct {
    BOOL enabled;
    double angle;    // degrees, 0 closed ... 180 flat
    double velocity; // degrees per second, positive while opening
    int state;       // HID hinge state byte, passed through unchanged
} VPhoneHingeState;

static inline BOOL VPhoneHingeNumber(id value) {
    return [value isKindOfClass:NSNumber.class] &&
           CFGetTypeID((__bridge CFTypeRef)value) != CFBooleanGetTypeID();
}

static inline BOOL VPhoneHingeDecode(id value, VPhoneHingeState *state) {
    *state = (VPhoneHingeState){NO, VP_HINGE_ANGLE_MAX, 0, 0};
    if (![value isKindOfClass:NSDictionary.class])
        return NO;
    id enabled = value[@"enabled"];
    if (![enabled isKindOfClass:NSNumber.class] ||
        CFGetTypeID((__bridge CFTypeRef)enabled) != CFBooleanGetTypeID())
        return NO;
    id angle = value[@"angle"], velocity = value[@"velocity"], hingeState = value[@"state"];
    if (!VPhoneHingeNumber(angle) || !VPhoneHingeNumber(velocity) || !VPhoneHingeNumber(hingeState))
        return NO;
    double a = [angle doubleValue], v = [velocity doubleValue];
    int s = [hingeState intValue];
    if (!isfinite(a) || a < 0 || a > VP_HINGE_ANGLE_MAX || !isfinite(v) || fabs(v) > VP_HINGE_VELOCITY_MAX ||
        s < 0 || s > 255)
        return NO;
    *state = (VPhoneHingeState){[enabled boolValue], a, v, s};
    return YES;
}

static inline NSDictionary *VPhoneHingeEncode(VPhoneHingeState state) {
    return @{@"enabled": @(state.enabled), @"angle": @(state.angle), @"velocity": @(state.velocity),
             @"state": @(state.state)};
}

// HID report interval, microseconds. Zero means there are no subscribers.
static inline uint64_t VPhoneHingeInterval(id value) {
    if (!VPhoneHingeNumber(value))
        return 0;
    double interval = [value doubleValue];
    if (!isfinite(interval) || interval <= 0)
        return 0;
    return (uint64_t)fmin(1000000, fmax(5000, interval));
}

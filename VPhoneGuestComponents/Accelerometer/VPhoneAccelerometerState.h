#pragma once
#import <Foundation/Foundation.h>
#include <math.h>

#define VP_ACCEL_DOMAIN "com.apple.backboardd"
#define VP_ACCEL_CONFIGURATION "VPhoneAccelerometerOrientation"
#define VP_ACCEL_STATUS "VPhoneAccelerometerStatus"
#define VP_ACCEL_NOTIFICATION "com.vphone.motion.accelerometer.changed"

typedef struct { double x, y, z; } VPhoneGravity;

// A stationary device in portrait by default. Units are g, as in IOHID's
// accelerometer events. These are device axes, not interface orientation:
// interface landscape-right (90 degrees) means device landscape-left.
static inline BOOL VPhoneAccelerometerDecode(id value, int *degrees) {
    *degrees = 0;
    if (![value isKindOfClass:NSNumber.class] ||
        CFGetTypeID((__bridge CFTypeRef)value) == CFBooleanGetTypeID())
        return NO;
    double number = [value doubleValue];
    if (!isfinite(number) || (number != 0 && number != 90 && number != 180 && number != 270))
        return NO;
    *degrees = (int)number;
    return YES;
}

static inline VPhoneGravity VPhoneAccelerometerGravity(int degrees) {
    switch (degrees) {
    case 90: return (VPhoneGravity){-1, 0, 0};
    case 180: return (VPhoneGravity){0, 1, 0};
    case 270: return (VPhoneGravity){1, 0, 0};
    default: return (VPhoneGravity){0, -1, 0};
    }
}

static inline int VPhoneAccelerometerDegrees(NSString *spec) {
    NSDictionary *values = @{
        @"0": @0, @"portrait": @0,
        @"90": @90, @"landscape-left": @90, @"left": @90,
        @"180": @180, @"upside-down": @180, @"portrait-upside-down": @180,
        @"270": @270, @"landscape-right": @270, @"right": @270,
    };
    NSNumber *value = values[spec.lowercaseString];
    return value ? value.intValue : -1;
}

static inline uint64_t VPhoneAccelerometerInterval(id value) {
    if (![value isKindOfClass:NSNumber.class] ||
        CFGetTypeID((__bridge CFTypeRef)value) == CFBooleanGetTypeID())
        return 0;
    double interval = [value doubleValue];
    return isfinite(interval) && interval > 0 ? (uint64_t)fmin(1000000, fmax(5000, interval)) : 0;
}

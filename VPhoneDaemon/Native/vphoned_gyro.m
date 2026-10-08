#import "Include/VphonedNative.h"
#import "../../VPhoneGuestComponents/Gyroscope/VPhoneGyroscopeState.h"
#include <notify.h>

static id VPhoneGyroscopeRead(CFStringRef key) {
    return CFBridgingRelease(CFPreferencesCopyValue(key, CFSTR(VP_GYRO_DOMAIN), CFSTR("mobile"),
                                                  kCFPreferencesAnyHost));
}

NSDictionary *vp_gyro_get(void) {
    CFPreferencesSynchronize(CFSTR(VP_GYRO_DOMAIN), CFSTR("mobile"), kCFPreferencesAnyHost);
    VPhoneGyroscopeState state;
    VPhoneGyroscopeDecode(VPhoneGyroscopeRead(CFSTR(VP_GYRO_CONFIGURATION)), &state);
    NSMutableDictionary *result = [VPhoneGyroscopeEncode(state) mutableCopy];
    result[@"units"] = @"rad/s";
    id status = VPhoneGyroscopeRead(CFSTR(VP_GYRO_STATUS));
    if ([status isKindOfClass:NSDictionary.class] &&
        [status[@"updated_at"] isKindOfClass:NSNumber.class] &&
        [status[@"enumerated"] isKindOfClass:NSNumber.class]) {
        result[@"provider"] = status;
        double age = [NSDate date].timeIntervalSince1970 - [status[@"updated_at"] doubleValue];
        result[@"provider_running"] = @([status[@"enumerated"] boolValue] && age >= 0 && age < 10);
    } else {
        result[@"provider"] = NSNull.null;
        result[@"provider_running"] = @NO;
    }
    return result;
}

BOOL vp_gyro_set(double x, double y, double z, bool enabled) {
    VPhoneGyroscopeState state = {enabled, x, y, z}, checked;
    NSDictionary *value = VPhoneGyroscopeEncode(state);
    if (!VPhoneGyroscopeDecode(value, &checked))
        return NO;
    CFPreferencesSetValue(CFSTR(VP_GYRO_CONFIGURATION), (__bridge CFDictionaryRef)value,
                          CFSTR(VP_GYRO_DOMAIN), CFSTR("mobile"), kCFPreferencesAnyHost);
    if (!CFPreferencesSynchronize(CFSTR(VP_GYRO_DOMAIN), CFSTR("mobile"), kCFPreferencesAnyHost))
        return NO;
    return notify_post(VP_GYRO_NOTIFICATION) == NOTIFY_STATUS_OK;
}

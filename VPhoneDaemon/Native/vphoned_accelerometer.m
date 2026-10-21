#import "Include/VphonedNative.h"
#import "../../VPhoneGuestComponents/Accelerometer/VPhoneAccelerometerState.h"
#include <errno.h>
#include <notify.h>
#include <signal.h>

NSDictionary *vp_accelerometer_get(void) {
    CFPreferencesSynchronize(CFSTR(VP_ACCEL_DOMAIN), CFSTR("mobile"), kCFPreferencesAnyHost);
    id value = CFBridgingRelease(CFPreferencesCopyValue(CFSTR(VP_ACCEL_CONFIGURATION),
        CFSTR(VP_ACCEL_DOMAIN), CFSTR("mobile"), kCFPreferencesAnyHost));
    int degrees;
    VPhoneAccelerometerDecode(value, &degrees);
    id status = CFBridgingRelease(CFPreferencesCopyValue(CFSTR(VP_ACCEL_STATUS),
        CFSTR(VP_ACCEL_DOMAIN), CFSTR("mobile"), kCFPreferencesAnyHost));
    BOOL running = NO;
    if ([status isKindOfClass:NSDictionary.class] &&
        [status[@"pid"] isKindOfClass:NSNumber.class] &&
        [status[@"updated_at"] isKindOfClass:NSNumber.class] &&
        [status[@"enumerated"] isKindOfClass:NSNumber.class] &&
        [status[@"report_interval_us"] isKindOfClass:NSNumber.class]) {
        pid_t pid = [status[@"pid"] intValue];
        BOOL alive = pid > 1 && (kill(pid, 0) == 0 || errno == EPERM);
        double age = NSDate.date.timeIntervalSince1970 - [status[@"updated_at"] doubleValue];
        BOOL flowing = [status[@"report_interval_us"] unsignedLongLongValue] > 0;
        running = [status[@"enumerated"] boolValue] && alive && age >= 0 && (age < 10 || !flowing);
    } else {
        status = NSNull.null;
    }
    return @{@"degrees": @(degrees), @"provider_running": @(running), @"provider": status};
}

BOOL vp_accelerometer_set_orientation(NSString *spec) {
    int degrees = VPhoneAccelerometerDegrees(spec);
    if (degrees < 0)
        return NO;
    CFPreferencesSetValue(CFSTR(VP_ACCEL_CONFIGURATION), (__bridge CFNumberRef)@(degrees),
                          CFSTR(VP_ACCEL_DOMAIN), CFSTR("mobile"), kCFPreferencesAnyHost);
    if (!CFPreferencesSynchronize(CFSTR(VP_ACCEL_DOMAIN), CFSTR("mobile"), kCFPreferencesAnyHost))
        return NO;
    return notify_post(VP_ACCEL_NOTIFICATION) == NOTIFY_STATUS_OK;
}

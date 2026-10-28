#import "Include/VphonedNative.h"
#import "../../VPhoneGuestComponents/Hinge/VPhoneHingeState.h"
#include <errno.h>
#include <notify.h>
#include <signal.h>

static id VPhoneHingeRead(CFStringRef key) {
    return CFBridgingRelease(CFPreferencesCopyValue(key, CFSTR(VP_HINGE_DOMAIN), CFSTR("mobile"),
                                                  kCFPreferencesAnyHost));
}

NSDictionary *vp_hinge_get(void) {
    CFPreferencesSynchronize(CFSTR(VP_HINGE_DOMAIN), CFSTR("mobile"), kCFPreferencesAnyHost);
    VPhoneHingeState state;
    VPhoneHingeDecode(VPhoneHingeRead(CFSTR(VP_HINGE_CONFIGURATION)), &state);
    NSMutableDictionary *result = [VPhoneHingeEncode(state) mutableCopy];
    result[@"units"] = @"degrees";
    id status = VPhoneHingeRead(CFSTR(VP_HINGE_STATUS));
    if ([status isKindOfClass:NSDictionary.class] && [status[@"enumerated"] isKindOfClass:NSNumber.class]) {
        result[@"provider"] = status;
        // The provider writes its status at every transition and every slider
        // change; the backboardd that wrote it must still be running.
        BOOL alive = NO;
        if ([status[@"pid"] isKindOfClass:NSNumber.class]) {
            pid_t pid = [status[@"pid"] intValue];
            alive = pid > 1 && (kill(pid, 0) == 0 || errno == EPERM);
        }
        result[@"provider_running"] = @([status[@"enumerated"] boolValue] && alive);
    } else {
        result[@"provider"] = NSNull.null;
        result[@"provider_running"] = @NO;
    }
    return result;
}

BOOL vp_hinge_set(double angle, double velocity, int state, bool enabled) {
    VPhoneHingeState value = {enabled, angle, velocity, state}, checked;
    NSDictionary *encoded = VPhoneHingeEncode(value);
    if (!VPhoneHingeDecode(encoded, &checked))
        return NO;
    CFPreferencesSetValue(CFSTR(VP_HINGE_CONFIGURATION), (__bridge CFDictionaryRef)encoded,
                          CFSTR(VP_HINGE_DOMAIN), CFSTR("mobile"), kCFPreferencesAnyHost);
    if (!CFPreferencesSynchronize(CFSTR(VP_HINGE_DOMAIN), CFSTR("mobile"), kCFPreferencesAnyHost))
        return NO;
    return notify_post(VP_HINGE_NOTIFICATION) == NOTIFY_STATUS_OK;
}

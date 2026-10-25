#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <os/log.h>

@interface UIFocusSystem (VPhoneTVSetupFocus)
- (id)behavior;
- (NSNumber *)_overrideFocusDeferralBehavior;
- (NSInteger)_effectiveFocusDeferralBehavior;
- (void)_setOverrideFocusDeferralBehavior:(NSNumber *)behavior;
@end

static void VPApplyPolicy(UIFocusSystem *changedSystem) {
    Class setupWindow = NSClassFromString(@"Setup.EventDroppingWindow");
    if (!setupWindow) return;
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class] ||
            scene.activationState != UISceneActivationStateForegroundActive) continue;
        for (UIWindow *window in ((UIWindowScene *)scene).windows) {
            if (!window.isKeyWindow || window.hidden || window.alpha <= 0 ||
                ![window isKindOfClass:setupWindow]) continue;
            UIFocusSystem *system = window.windowScene.focusSystem;
            if (!system || (changedSystem && system != changedSystem)) continue;
            if (![NSStringFromClass(object_getClass([system behavior])) isEqualToString:@"_UIFocusBehavior_WaffleIron"] ||
                [system _overrideFocusDeferralBehavior] || [system _effectiveFocusDeferralBehavior] != 3) continue;
            // The new assistant's WaffleIron policy defers focus after 60s.
            // Consumer Select does not restore that deferred target.
            // Use the native TV button-focus policy (TV.focusDeferral == 0).
            // The setter performs UIKit's normal preferred-focus and eligibility
            // checks; Setup's press, drawing, scene and completion logic is intact.
            [system _setOverrideFocusDeferralBehavior:@0];
            os_log(OS_LOG_DEFAULT, "[TVSetupFocus] Enabled native TV button-focus policy");
        }
    }
}

static void VPSchedulePolicy(UIFocusSystem *changedSystem) {
    // A focus-drop notification precedes storage of the deferred target.
    // Recheck current windows after that native update completes.
    dispatch_async(dispatch_get_main_queue(), ^{ VPApplyPolicy(changedSystem); });
}

static void VPInstall(void) {
    Method setter = class_getInstanceMethod(UIFocusSystem.class, @selector(_setOverrideFocusDeferralBehavior:));
    Method override = class_getInstanceMethod(UIFocusSystem.class, @selector(_overrideFocusDeferralBehavior));
    Method effective = class_getInstanceMethod(UIFocusSystem.class, @selector(_effectiveFocusDeferralBehavior));
    Method behavior = class_getInstanceMethod(UIFocusSystem.class, @selector(behavior));
    if (!setter || method_getNumberOfArguments(setter) != 3 || method_getTypeEncoding(setter)[0] != 'v' ||
        !override || method_getTypeEncoding(override)[0] != '@' ||
        !effective || (method_getTypeEncoding(effective)[0] != 'q' && method_getTypeEncoding(effective)[0] != 'Q') ||
        !behavior || method_getTypeEncoding(behavior)[0] != '@') return;
    for (NSNotificationName name in @[UISceneDidActivateNotification, UIWindowDidBecomeKeyNotification, UIFocusDidUpdateNotification]) {
        [NSNotificationCenter.defaultCenter addObserverForName:name object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *note) {
            VPSchedulePolicy([note.name isEqualToString:UIFocusDidUpdateNotification] ? note.object : nil);
        }];
    }
    VPSchedulePolicy(nil);
}

__attribute__((constructor)) static void VPInitialize(void) {
    NSOperatingSystemVersion version = NSProcessInfo.processInfo.operatingSystemVersion;
    if (version.majorVersion != 27 || version.minorVersion != 2 ||
        ![NSBundle.mainBundle.bundleIdentifier isEqualToString:@"com.apple.Setup"]) return;
    dispatch_async(dispatch_get_main_queue(), ^{ VPInstall(); });
}

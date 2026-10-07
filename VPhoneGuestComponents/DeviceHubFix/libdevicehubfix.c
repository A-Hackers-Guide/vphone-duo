// libdevicehubfix.c — let Xcode's DeviceHub show a vphone guest's screen.
//
// DeviceHub (Xcode 27) views a device through the developer disk image's
// dtremotedisplayd. On a vphone guest it needs three fixes, one per process:
// cryptexd mounts the DDI, dtremotedisplayd reports media stream features,
// and dtdeviceinfod supplies the framebuffer mask.
//
// ## cryptexd: the DDI does not mount on iOS 27
//
// On iOS 27 the DDI is a cryptex, and cryptexd stages its assets before it
// grafts them. For each one it opens the staged copy and asks for data
// protection class D:
//
//     fd = open(path, O_RDWR);
//     if (fcntl(fd, F_SETPROTECTIONCLASS, 4) == -1 && errno != ENOTSUP)
//         fail;                  // "set protection class: %{darwin.errno}d"
//
// A guest answers EPERM, so staging fails ("copy asset: im4m: [1: Operation
// not permitted]", "system: staging failed") and CoreDevice reports the
// device as "connected (no DDI)" for good. Measured on iPhone17,3 27.0.1
// (24A446). iOS 26 guests mount the DDI without this.
//
// cryptexd already accepts a filesystem that does not do protection classes
// (ENOTSUP). An EPERM from F_SETPROTECTIONCLASS is reported as ENOTSUP, so it
// takes that path; every other fcntl, and every other failure, is untouched.
//
// ## dtremotedisplayd: no media stream features
//
// Before it starts a stream, DeviceHub asks the device which media stream
// features it has (MediaStreamGetSupportInfo) and keeps asking, with backoff,
// until the answer is non-empty. A guest always answers
//
//     SupportInfo: supportedFeatures: 0 (No supported features are available),
//         avcFrameworkVersion: "2215.5.1"
//
// so the viewer spins forever. dtremotedisplayd takes the answer from
// `MediaStreamSupportedFeatures.current` in the DDI's CoreDeviceUtilities
// (CoreDevice-642.16, Xcode 27A266a), whose policy refuses, among others:
//
//   "Remote control restricted. Device is customer-restricted (production
//    fused, customer OS, customer DDI) and running pre-27.0 OS" — every
//    26.x guest: `CurrentDevice.isCustomerRestricted` is
//    `isProductionFused && !hasInternalOSBuild && hasInternalDDI == false`.
//   "Remote control is only available on iOS 27.0, watchOS 27.0, or tvOS
//    27.0 or later … the device is not an iPhone, Apple Watch, or Apple TV"
//    — every iPad guest, whatever its version.
//
// Neither is a capability check. The stream itself is AVConference screen
// capture inside the guest, which does not ask either of them.
//
// The getter is interposed to answer with the features a Mac host offers
// (primary display mirrored video, system audio and display information), and
// `isCustomerRestricted`, which dtremotedisplayd also reads, answers no. The
// host still intersects the answer with its own features, so asking for more
// than the Mac can take changes nothing.
//
// ## dtdeviceinfod: missing framebuffer mask
//
// dtdeviceinfod answers DeviceHub's DisplayInfo from MobileGestalt. The 27.x
// iPhone guest reports `ChromeIdentifier` phone11 but no `FramebufferIdentifier`,
// so DeviceHub falls back to a rounded rectangle and draws the screen over the
// bezel corners. Only that missing answer is filled, with the phone11 mask from
// Xcode's /Library/Developer/DeviceKit/chrome_map.plist; existing answers and
// other chromes pass through, and the result keeps the Copy ownership rule.
//
// ## Reach
//
// The interposes reach their callers because cryptexd, dtremotedisplayd,
// dtdeviceinfod and CoreDeviceUtilities are standalone images, not shared-cache
// ones: dyld binds their imports through the interposing table.
// CoreDeviceUtilities is on the DDI and not in the SDK, so its two symbols are
// weak flat-namespace imports; outside dtremotedisplayd they resolve to nothing
// and dyld skips those entries. The spawn hooks insert this into those three
// processes only — `vpIsDeviceHubFixTarget` in Shared/InjectionEnvironment.h.

#include <errno.h>
#include <fcntl.h>
#include <stdarg.h>
#include <stdatomic.h>
#include <stdio.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>
#include <CoreFoundation/CoreFoundation.h>

extern CFTypeRef MGCopyAnswer(CFStringRef key, CFDictionaryRef options);

// The features a Mac host reports for itself (raw 0x8c): primary display
// mirrored output 0x4, system audio output 0x8, display information 0x80.
#define VP_DEVICEHUB_FEATURES 0x8c

#define VP_STRINGIFY_(value) #value
#define VP_STRINGIFY(value) VP_STRINGIFY_(value)

// MARK: - Log

// dtremotedisplayd runs as mobile and cryptexd as root; the mode keeps a root
// writer of the same log from silencing later ones, as in SystemHook.
static void vpLog(const char *format, const char *a, const char *b) {
    int fd = open("/var/mobile/Library/Caches/vphone-devicehubfix.log",
                  O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC, 0666);
    if (fd < 0)
        return;
    fchmod(fd, 0666);
    dprintf(fd, "pid=%d ", getpid());
    dprintf(fd, format, a, b);
    dprintf(fd, "\n");
    close(fd);
}

// MARK: - cryptexd

static int vpFcntl(int fd, int command, ...) {
    va_list arguments;
    va_start(arguments, command);
    void *argument = va_arg(arguments, void *);
    va_end(arguments);
    int result = fcntl(fd, command, argument);
    if (result == -1 && command == F_SETPROTECTIONCLASS && errno == EPERM) {
        static atomic_int logged;
        if (!atomic_exchange(&logged, 1))
            vpLog("F_SETPROTECTIONCLASS %s, reported as %s", "EPERM", "ENOTSUP");
        errno = ENOTSUP;
    }
    return result;
}

// MARK: - dtremotedisplayd

// static MediaStreamSupportedFeatures.current.getter
// MediaStreamSupportedFeatures is a resilient struct (the framework is built
// for library evolution), so the getter returns it indirectly through x8.
extern void vpOriginalCurrentFeatures(void)
    __asm__("_$s19CoreDeviceUtilities28MediaStreamSupportedFeaturesV7currentACvgZ") __attribute__((weak_import));
// CurrentDevice.isCustomerRestricted.getter -> Bool
extern void vpOriginalIsCustomerRestricted(void)
    __asm__("_$s19CoreDeviceUtilities07CurrentB0V20isCustomerRestrictedSbvg") __attribute__((weak_import));

__attribute__((naked)) static void vpCurrentFeatures(void) {
    __asm__ volatile("mov x9, #" VP_STRINGIFY(VP_DEVICEHUB_FEATURES) "\n"
                     "str x9, [x8]\n"
                     "ret\n");
}

__attribute__((naked)) static void vpIsCustomerRestricted(void) {
    __asm__ volatile("mov w0, #0\n"
                     "ret\n");
}

__attribute__((constructor)) static void vpLogLoad(void) {
    if (vpOriginalCurrentFeatures || vpOriginalIsCustomerRestricted)
        vpLog("media stream features=" VP_STRINGIFY(VP_DEVICEHUB_FEATURES) " current=%s isCustomerRestricted=%s",
              vpOriginalCurrentFeatures ? "interposed" : "absent",
              vpOriginalIsCustomerRestricted ? "interposed" : "absent");
}

// Fill the missing mask and preserve Copy ownership. Bounded diagnostics log
// only the three identifiers consumed by the DDI DisplayInfoProvider.
static CFTypeRef vpDisplayAnswer(CFStringRef key, CFDictionaryRef options) {
    CFTypeRef result = MGCopyAnswer(key, options);
    // The virtual board advertises phone11 chrome but no framebuffer mask.
    // DDI metadata only: use the matching mask shipped in Xcode's
    // /Library/Developer/DeviceKit/chrome_map.plist. Keep real answers intact.
    if (!result && key && !strcmp(getprogname(), "dtdeviceinfod") &&
        CFEqual(key, CFSTR("FramebufferIdentifier"))) {
        CFTypeRef chrome = MGCopyAnswer(CFSTR("ChromeIdentifier"), NULL);
        if (chrome && CFEqual(chrome, CFSTR("com.apple.dt.devicekit.chrome.phone11")))
            result = CFRetain(CFSTR("4E5532ED-1470-47D1-BDF4-7AA90C26957A"));
        if (chrome) CFRelease(chrome);
    }
    if (key && (!strcmp(getprogname(), "dtdeviceinfod")) &&
        (CFEqual(key, CFSTR("FramebufferIdentifier")) ||
         CFEqual(key, CFSTR("ChromeIdentifier")) ||
         CFEqual(key, CFSTR("DisplayExtendedProperties")))) {
        static atomic_uint count;
        if (atomic_fetch_add(&count, 1) < 12) {
            char name[128] = {0}, value[4096] = {0};
            CFStringGetCString(key, name, sizeof(name), kCFStringEncodingUTF8);
            CFStringRef description = result ? CFCopyDescription(result) : NULL;
            if (description) {
                CFStringGetCString(description, value, sizeof(value), kCFStringEncodingUTF8);
                CFRelease(description);
            }
            vpLog("display %s = %s", name, result ? value : "<null>");
        }
    }
    return result;
}

int vphone_devicehubfix_version(void) { return 2; }

__attribute__((used, section("__DATA,__interpose"))) static const struct {
    const void *replacement;
    const void *replacee;
} vpInterpose[] = {
    {(const void *)vpDisplayAnswer, (const void *)MGCopyAnswer},
    {(const void *)vpFcntl, (const void *)fcntl},
    {(const void *)vpCurrentFeatures, (const void *)vpOriginalCurrentFeatures},
    {(const void *)vpIsCustomerRestricted, (const void *)vpOriginalIsCustomerRestricted},
};

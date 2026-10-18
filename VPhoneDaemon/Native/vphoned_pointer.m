/*
 * vphoned_pointer — a virtual pointing device, for native scrolling.
 *
 * A scroll made of touches is a finger that drags and lets go, and how far the
 * content runs on afterwards is the guest's guess at the finger's speed from
 * the times the moves arrive. Over a network those times bunch up, so the
 * run-on changes from one swipe to the next. A pointing device scrolls the way
 * an iPad with a trackpad does: the view under the pointer moves by exactly
 * the deltas given, and nothing runs on that the client did not send.
 *
 * The device is a HID user device that reports an absolute position, so
 * iPadOS shows its pointer and puts it where a report says, in the interface's
 * own orientation (measured on iPadOS 26 in portrait and landscape); the
 * pointer hides itself when it has been still for a few seconds. Scroll
 * events are dispatched with that device's event service as their sender:
 * with any other sender (the touchscreen's included) they reach nothing, or
 * the view at the top-left corner. The device is created on first use and
 * lives as long as vphoned.
 *
 * Every entry point is resolved with dlsym, like vphoned_touch.m.
 */

#import "Include/VphonedNative.h"

#include <dlfcn.h>
#include <mach/mach_time.h>
#include <math.h>
#include <unistd.h>

typedef void *IOHIDEventSystemClientRef;
typedef void *IOHIDEventRef;
typedef void *IOHIDUserDeviceRef;
typedef double IOHIDFloat;
typedef unsigned int vp_io_object_t;

static IOHIDEventSystemClientRef (*pClientCreate)(CFAllocatorRef);
static void (*pDispatch)(IOHIDEventSystemClientRef, IOHIDEventRef);
static void (*pSetSender)(IOHIDEventRef, uint64_t);
static IOHIDEventRef (*pScroll)(CFAllocatorRef, uint64_t, IOHIDFloat, IOHIDFloat, IOHIDFloat, uint32_t);
static void (*pSetPhase)(IOHIDEventRef, uint32_t);
static IOHIDUserDeviceRef (*pDeviceCreate)(CFAllocatorRef, CFDictionaryRef);
static int (*pHandleReport)(IOHIDUserDeviceRef, const uint8_t *, CFIndex);
static CFMutableDictionaryRef (*pMatching)(const char *);
static int (*pMatchingServices)(unsigned int, CFDictionaryRef, vp_io_object_t *);
static vp_io_object_t (*pNext)(vp_io_object_t);
static CFTypeRef (*pSearchProperty)(vp_io_object_t, const char *, CFStringRef, CFAllocatorRef, uint32_t);
static int (*pEntryID)(vp_io_object_t, uint64_t *);
static int (*pRelease)(vp_io_object_t);

static dispatch_queue_t gPointerQueue;
static bool gPointerLoaded;
static IOHIDEventSystemClientRef gPointerClient;
static IOHIDUserDeviceRef gPointerDevice;
static uint64_t gPointerSender;
static uint64_t gPointerLastSequence;

static NSString *const kPointerProduct = @"vphone pointer";

// Three buttons (never pressed), an absolute X and Y within 0...32767, a wheel
// and a horizontal pan (never turned). Without the wheel and the pan iPadOS
// shows the pointer but sends the scroll events nowhere.
static const uint8_t kPointerDescriptor[] = {
    0x05, 0x01, 0x09, 0x02, 0xA1, 0x01, 0x09, 0x01, 0xA1, 0x00,
    0x05, 0x09, 0x19, 0x01, 0x29, 0x03, 0x15, 0x00, 0x25, 0x01, 0x95, 0x03, 0x75, 0x01, 0x81, 0x02,
    0x95, 0x01, 0x75, 0x05, 0x81, 0x03,
    0x05, 0x01, 0x09, 0x30, 0x09, 0x31, 0x15, 0x00, 0x26, 0xFF, 0x7F, 0x75, 0x10, 0x95, 0x02, 0x81, 0x02,
    0x09, 0x38, 0x15, 0x81, 0x25, 0x7F, 0x75, 0x08, 0x95, 0x01, 0x81, 0x06,
    0x05, 0x0C, 0x0A, 0x38, 0x02, 0x15, 0x81, 0x25, 0x7F, 0x75, 0x08, 0x95, 0x01, 0x81, 0x06,
    0xC0, 0xC0,
};
static const double kPointerMaximum = 32767;

// kIORegistryIterateRecursively | kIORegistryIterateParents
#define VP_SEARCH_UP 3u

static bool load_symbols(void) {
    if (gPointerLoaded) return true;
    void *ioKit = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_NOW);
    if (!ioKit) return false;
    pClientCreate = dlsym(ioKit, "IOHIDEventSystemClientCreate");
    pDispatch = dlsym(ioKit, "IOHIDEventSystemClientDispatchEvent");
    pSetSender = dlsym(ioKit, "IOHIDEventSetSenderID");
    pScroll = dlsym(ioKit, "IOHIDEventCreateScrollEvent");
    pSetPhase = dlsym(ioKit, "IOHIDEventSetPhase");
    pDeviceCreate = dlsym(ioKit, "IOHIDUserDeviceCreate");
    pHandleReport = dlsym(ioKit, "IOHIDUserDeviceHandleReport");
    pMatching = dlsym(ioKit, "IOServiceMatching");
    pMatchingServices = dlsym(ioKit, "IOServiceGetMatchingServices");
    pNext = dlsym(ioKit, "IOIteratorNext");
    pSearchProperty = dlsym(ioKit, "IORegistryEntrySearchCFProperty");
    pEntryID = dlsym(ioKit, "IORegistryEntryGetRegistryEntryID");
    pRelease = dlsym(ioKit, "IOObjectRelease");
    gPointerLoaded = pClientCreate && pDispatch && pSetSender && pScroll && pSetPhase && pDeviceCreate &&
                     pHandleReport && pMatching && pMatchingServices && pNext && pSearchProperty && pEntryID &&
                     pRelease;
    return gPointerLoaded;
}

// The registry ID of the event service iOS put over the device, which is the
// sender its own events carry.
static uint64_t find_sender(void) {
    vp_io_object_t iterator = 0;
    if (pMatchingServices(0, pMatching("IOHIDEventService"), &iterator) != 0) return 0;
    uint64_t found = 0;
    vp_io_object_t service;
    while ((service = pNext(iterator))) {
        CFTypeRef product = pSearchProperty(service, "IOService", CFSTR("Product"), kCFAllocatorDefault, VP_SEARCH_UP);
        if (!found && product && CFGetTypeID(product) == CFStringGetTypeID() &&
            CFStringCompare(product, (__bridge CFStringRef)kPointerProduct, 0) == kCFCompareEqualTo) {
            pEntryID(service, &found);
        }
        if (product) CFRelease(product);
        pRelease(service);
    }
    pRelease(iterator);
    return found;
}

// On gPointerQueue. The event service appears a moment after the device;
// waits up to a second for it.
static int ensure_device(void) {
    if (gPointerSender) return VP_POINTER_OK;
    if (!load_symbols()) return VP_POINTER_UNAVAILABLE;
    if (!gPointerClient) gPointerClient = pClientCreate(kCFAllocatorDefault);
    if (!gPointerClient) return VP_POINTER_UNAVAILABLE;
    if (!gPointerDevice) {
        NSDictionary *properties = @{
            @"ReportDescriptor": [NSData dataWithBytes:kPointerDescriptor length:sizeof(kPointerDescriptor)],
            @"VendorID": @0x05AC,
            @"ProductID": @0x7650,
            @"Product": kPointerProduct,
            @"Transport": @"USB",
            @"PrimaryUsagePage": @1,
            @"PrimaryUsage": @2,
        };
        gPointerDevice = pDeviceCreate(kCFAllocatorDefault, (__bridge CFDictionaryRef)properties);
        if (!gPointerDevice) {
            NSLog(@"vphoned: IOHIDUserDeviceCreate refused the pointer device");
            return VP_POINTER_REFUSED;
        }
    }
    for (int attempt = 0; attempt < 50 && !gPointerSender; attempt++) {
        gPointerSender = find_sender();
        if (!gPointerSender) usleep(20000);
    }
    return gPointerSender ? VP_POINTER_OK : VP_POINTER_NOT_READY;
}

static dispatch_queue_t pointer_queue(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        dispatch_queue_attr_t attributes = dispatch_queue_attr_make_with_qos_class(
            DISPATCH_QUEUE_SERIAL, QOS_CLASS_USER_INTERACTIVE, 0);
        gPointerQueue = dispatch_queue_create("com.vphone.vphoned.pointer", attributes);
    });
    return gPointerQueue;
}

int vp_pointer_move(double x, double y, uint64_t sequence) {
    __block int result;
    dispatch_sync(pointer_queue(), ^{
        result = ensure_device();
        if (result != VP_POINTER_OK) return;
        // Requests run concurrently, so a move sent earlier can land later;
        // putting the pointer back where it was would make it jump.
        if (sequence) {
            if (sequence <= gPointerLastSequence) return;
            gPointerLastSequence = sequence;
        }
        uint16_t px = (uint16_t)lround(fmin(fmax(x, 0), 1) * kPointerMaximum);
        uint16_t py = (uint16_t)lround(fmin(fmax(y, 0), 1) * kPointerMaximum);
        const uint8_t report[7] = {0, px & 0xFF, px >> 8, py & 0xFF, py >> 8, 0, 0};
        if (pHandleReport(gPointerDevice, report, sizeof(report)) != 0) result = VP_POINTER_FAILED;
    });
    return result;
}

int vp_pointer_scroll(int phase, double dx, double dy) {
    __block int result;
    dispatch_sync(pointer_queue(), ^{
        result = ensure_device();
        if (result != VP_POINTER_OK) return;
        IOHIDEventRef event = pScroll(kCFAllocatorDefault, mach_absolute_time(), dx, dy, 0, 0);
        if (!event) {
            result = VP_POINTER_FAILED;
            return;
        }
        pSetPhase(event, (uint32_t)phase);
        pSetSender(event, gPointerSender);
        pDispatch(gPointerClient, event);
        CFRelease(event);
    });
    return result;
}

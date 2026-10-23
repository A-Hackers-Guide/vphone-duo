#import <Foundation/Foundation.h>
#include <assert.h>
extern bool VPHomePodInstallDisplayIdentity(void);

static int opens;
static int closes;
static int scans;
static CFTypeRef replacement;
static CFTypeRef failedDevice;
CFTypeRef VPHomePodHIDProperty(CFTypeRef device, CFStringRef key) { return CFDictionaryGetValue(device, key); }
int VPHomePodHIDOpen(CFTypeRef device) { (void)device; opens++; return 0; }
void VPHomePodHIDClose(CFTypeRef device) { (void)device; closes++; }
CFTypeRef VPHomePodCopyDisplay(void) { scans++; return replacement ? CFRetain(replacement) : NULL; }

@interface MDInterfaceHID : NSObject {
@public
    CFTypeRef _device;
    dispatch_semaphore_t _sema;
}
@property NSDictionary *properties;
@property int originalAddedCount;
- (id)_getPropertyForKey:(NSString *)key error:(NSError **)error;
- (void)deviceAdded:(CFTypeRef)device;
- (BOOL)submitFrame:(id)frame error:(NSError **)error;
@end
@implementation MDInterfaceHID
- (void)deviceAdded:(CFTypeRef)device { (void)device; self.originalAddedCount++; }
- (void)dealloc { if (_device) CFRelease(_device); }
- (BOOL)submitFrame:(id)frame error:(NSError **)error {
    (void)frame;
    if (_device == failedDevice) {
        if (error) *error = [NSError errorWithDomain:@"OriginalSubmit" code:1 userInfo:nil];
        return NO;
    }
    return YES;
}
- (id)_getPropertyForKey:(NSString *)key error:(NSError **)error {
    id value = self.properties[key];
    if (!value && error) *error = [NSError errorWithDomain:@"OriginalProperty" code:1 userInfo:nil];
    return value;
}
@end

int main(void) { @autoreleasepool {
    assert(VPHomePodInstallDisplayIdentity());
    assert(VPHomePodInstallDisplayIdentity());
    MDInterfaceHID *device = [MDInterfaceHID new];
    device.properties = @{@"PhysicalDeviceUniqueID":@"vphone-homepod-mini-display", @"MDHWVersion":@3};
    assert([[device _getPropertyForKey:@"IOClass" error:NULL] isEqual:@"MiniDisplayDriver"]);
    assert([[device _getPropertyForKey:@"MDHWVersion" error:NULL] isEqual:@3]);
    NSError *error = nil;
    assert([device _getPropertyForKey:@"absent" error:&error] == nil);
    assert([error.domain isEqual:@"OriginalProperty"]);
    for (id identity in @[@"other-display", @123, NSNull.null]) {
        device.properties = @{@"PhysicalDeviceUniqueID":identity,@"IOClass":@"PhysicalDriver"};
        assert([[device _getPropertyForKey:@"IOClass" error:NULL] isEqual:@"PhysicalDriver"]);
    }
    device.properties = @{};
    error = nil;
    assert([device _getPropertyForKey:@"IOClass" error:&error] == nil && error != nil);
    device->_sema = dispatch_semaphore_create(0);
    NSDictionary *hid = @{@"PhysicalDeviceUniqueID":@"vphone-homepod-mini-display"};
    [device deviceAdded:(__bridge CFTypeRef)hid];
    assert(opens == 1 && device->_device == (__bridge CFTypeRef)hid && device.originalAddedCount == 0);
    assert(dispatch_semaphore_wait(device->_sema, DISPATCH_TIME_NOW) == 0);
    [device deviceAdded:(__bridge CFTypeRef)hid];
    assert(opens == 1);
    [device deviceAdded:(__bridge CFTypeRef)@{@"PhysicalDeviceUniqueID":@"another-device"}];
    assert(device.originalAddedCount == 1);
    assert([device submitFrame:@1 error:NULL] && scans == 0);
    failedDevice = device->_device;
    NSDictionary *newHID = @{@"PhysicalDeviceUniqueID":@"vphone-homepod-mini-display", @"generation":@2};
    replacement = (__bridge CFTypeRef)newHID;
    error = nil;
    assert([device submitFrame:@1 error:&error] && error == nil);
    assert(device->_device == replacement && opens == 2 && closes == 1 && scans == 1);
    // A physical device failure retains its handle and its original error.
    MDInterfaceHID *physical = [MDInterfaceHID new];
    physical->_device = CFRetain((__bridge CFTypeRef)@{@"PhysicalDeviceUniqueID":@"physical"});
    failedDevice = physical->_device;
    error = nil;
    assert(![physical submitFrame:@1 error:&error] && [error.domain isEqual:@"OriginalSubmit"]);
    assert(scans == 1 && closes == 1);
    // If the virtual replacement has not appeared yet, retries are throttled.
    failedDevice = device->_device;
    error = nil;
    assert(![device submitFrame:@1 error:&error] && [error.domain isEqual:@"OriginalSubmit"]);
    assert(scans == 1 && device->_device == failedDevice);
    puts("HomePod display identity tests passed");
} }

#import <Foundation/Foundation.h>
#include "../FoldGuard/libvphonefoldguard.m"

// This is intentionally not a valid ObjC object. The old id-return wrapper
// sends retain to it; the correct wrapper must pass its address untouched.
static struct { uintptr_t invalidISA; uint64_t payload; } opaqueLayer = {0x123456789abcdef0, 42};
static uintptr_t argumentsSeen[3];
static BOOL throwCopy, returnNull;

@interface VPFoldGuardFixture : NSObject
- (void *)copyLayer:(void *)pointer layerFlags:(uint32_t)flags commitFlags:(uint32_t *)commit;
- (id)objectResult:(void *)pointer layerFlags:(uint32_t)flags commitFlags:(uint32_t *)commit;
- (void *)floatArgument:(double)value layerFlags:(uint32_t)flags commitFlags:(uint32_t *)commit;
@end
@implementation VPFoldGuardFixture
- (void *)copyLayer:(void *)pointer layerFlags:(uint32_t)flags commitFlags:(uint32_t *)commit {
    argumentsSeen[0] = (uintptr_t)pointer; argumentsSeen[1] = flags; argumentsSeen[2] = (uintptr_t)commit;
    if (throwCopy) @throw [NSException exceptionWithName:@"CASecureIndicatorLayerInvalidName" reason:@"fixture" userInfo:nil];
    return returnNull ? NULL : &opaqueLayer;
}
- (id)objectResult:(void *)pointer layerFlags:(uint32_t)flags commitFlags:(uint32_t *)commit { return self; }
- (void *)floatArgument:(double)value layerFlags:(uint32_t)flags commitFlags:(uint32_t *)commit { return NULL; }
@end

int main(void) {
    @autoreleasepool {
        VPFoldGuardFixture *fixture = [VPFoldGuardFixture new];
        SEL selector = @selector(copyLayer:layerFlags:commitFlags:);
        Method method = class_getInstanceMethod(VPFoldGuardFixture.class, selector);
        NSCAssert(vpCopyRenderABIIsSupported(method), @"native pointer/integer ABI should be accepted");
        NSCAssert(!vpCopyRenderABIIsSupported(class_getInstanceMethod(VPFoldGuardFixture.class, @selector(objectResult:layerFlags:commitFlags:))), @"ObjC object result must not be treated as C++ pointer");
        NSCAssert(!vpCopyRenderABIIsSupported(class_getInstanceMethod(VPFoldGuardFixture.class, @selector(floatArgument:layerFlags:commitFlags:))), @"FP-register argument must be refused");
        vpOriginalCopyRender = method_getImplementation(method);
        void *(*guard)(id, SEL, uintptr_t, uintptr_t, uintptr_t) = (void *)vpGuardedCopyRender;
        uint32_t commit = 9;
        void *returned = guard(fixture, selector, (uintptr_t)&opaqueLayer, 0xfedcba98, (uintptr_t)&commit);
        NSCAssert(returned == &opaqueLayer, @"non-ObjC layer must pass through without ARC ownership");
        NSCAssert(argumentsSeen[0] == (uintptr_t)&opaqueLayer && argumentsSeen[1] == 0xfedcba98 && argumentsSeen[2] == (uintptr_t)&commit, @"all argument registers must be forwarded");
        returnNull = YES;
        NSCAssert(guard(fixture, selector, 0, 0, 0) == NULL, @"normal null result must pass through");
        throwCopy = YES;
        NSCAssert(guard(fixture, selector, 0, 0, 0) == NULL, @"exception fallback must return a null opaque pointer");
        puts("FoldGuard: 7 checks passed");
    }
    return 0;
}

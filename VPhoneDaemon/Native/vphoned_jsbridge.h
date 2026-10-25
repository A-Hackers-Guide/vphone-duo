#pragma once
#import <Foundation/Foundation.h>
#import <JavaScriptCore/JavaScriptCore.h>

/// What a script holds for an ObjC object the bridge cannot convert. The
/// prelude wraps each one in a proxy, so a script calls methods by name
/// instead of calling `send` itself.
@protocol VPObjCHandleExports <JSExport>
@property (nonatomic, readonly) BOOL objcHandle;
@property (nonatomic, readonly) NSString *className;
@property (nonatomic, readonly) BOOL isClassHandle;
- (NSString *)toString;
/// The object as a plain JavaScript value: a collection becomes an array or
/// an object, and anything else its description.
- (JSValue *)plainValue;
JSExportAs(send, - (JSValue *)sendSelectorNamed:(NSString *)name arguments:(JSValue *)arguments);
@end

@interface VPObjCHandle : NSObject <VPObjCHandleExports>
@property (nonatomic, readonly, strong) id target;
+ (instancetype)handleFor:(id)target;
@end

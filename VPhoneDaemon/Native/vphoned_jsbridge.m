#import "vphoned_jsbridge.h"

#import <objc/runtime.h>

// Reflection is the point of the session: without it a script can only do
// arithmetic, and the frameworks a guest keeps to itself are exactly what
// there is no other way to reach. NSInvocation covers every method the
// runtime can describe, which is every method but a variadic one.

static bool vp_bridge_is_value(id object);

/// Whether the method returns an object ARC has not accounted for, by the
/// same rule the compiler uses: a selector whose first word is alloc, new,
/// copy, mutableCopy or init belongs to that family. The word has to end
/// there, so `copyWithZone:` is in the family and `copyingProgress` is not —
/// taking ownership of a borrowed object would over-release it.
static bool vp_bridge_in_family(NSString *name, NSString *family) {
    if (![name hasPrefix:family]) return false;
    if (name.length == family.length) return true;
    unichar next = [name characterAtIndex:family.length];
    return next < 'a' || next > 'z';
}

static bool vp_bridge_returns_retained(SEL selector) {
    NSString *name = NSStringFromSelector(selector);
    for (NSString *family in @[@"alloc", @"new", @"copy", @"mutableCopy", @"init"]) {
        if (vp_bridge_in_family(name, family)) return true;
    }
    return false;
}

/// An allocated object is not yet an object: NSString's allocation is a
/// placeholder that raises on anything but an initializer, and asking JSC to
/// convert it as a string would be one such message. It is handed back as a
/// handle, whatever it claims to be a kind of.
static bool vp_bridge_returns_placeholder(SEL selector) {
    return vp_bridge_in_family(NSStringFromSelector(selector), @"alloc");
}

/// A method encoding carries qualifiers the type itself does not: `const char *`
/// arrives as `r*`, and in, out and inout parameters are prefixed as well.
/// None of them change how the value is passed.
static const char *vp_bridge_unqualified(const char *type) {
    while (*type && strchr("rnNoORV", *type)) type++;
    return type;
}

@implementation VPObjCHandle

+ (instancetype)handleFor:(id)target {
    if (!target) return nil;
    VPObjCHandle *handle = [VPObjCHandle new];
    handle->_target = target;
    return handle;
}

- (BOOL)objcHandle {
    return YES;
}

- (NSString *)className {
    Class owner = object_isClass(_target) ? _target : [_target class];
    return NSStringFromClass(owner);
}

- (BOOL)isClassHandle {
    return object_isClass(_target);
}

- (JSValue *)plainValue {
    JSContext *context = [JSContext currentContext];
    if (vp_bridge_is_value(_target) || [_target isKindOfClass:[NSArray class]] ||
        [_target isKindOfClass:[NSDictionary class]]) {
        return [JSValue valueWithObject:_target inContext:context];
    }
    return [JSValue valueWithObject:[self toString] inContext:context];
}

- (NSString *)toString {
    NSString *description = nil;
    @try {
        description = [_target description];
    } @catch (NSException *exception) {
        description = [NSString stringWithFormat:@"<%@: description threw %@>", self.className, exception.name];
    }
    return description ?: [NSString stringWithFormat:@"<%@>", self.className];
}

// MARK: - Dispatch

/// Whether JSC's own conversion carries everything the object is: a string, a
/// number and a date are values, and so is a collection of them.
static bool vp_bridge_is_value(id object) {
    return [object isKindOfClass:[NSString class]] || [object isKindOfClass:[NSNumber class]] ||
           [object isKindOfClass:[NSDate class]] || [object isKindOfClass:[NSNull class]];
}

/// A script sees a string or a number where ObjC returned one, and a handle
/// for everything else, collections included: converting an NSArray would
/// hand back a copy, and a script that asked for a mutable one wants the
/// object. `$value` converts when that is what was wanted.
static JSValue *vp_bridge_result(id object, JSContext *context) {
    if (!object) return [JSValue valueWithNullInContext:context];
    if (vp_bridge_is_value(object)) return [JSValue valueWithObject:object inContext:context];
    return [JSValue valueWithObject:[VPObjCHandle handleFor:object] inContext:context];
}

static void vp_bridge_throw(JSContext *context, NSString *format, ...) {
    va_list arguments;
    va_start(arguments, format);
    NSString *message = [[NSString alloc] initWithFormat:format arguments:arguments];
    va_end(arguments);
    context.exception = [JSValue valueWithNewErrorFromMessage:message inContext:context];
}

/// The target object behind a JS value: a handle for anything the bridge
/// returned, and JSC's own conversion for a string, number, array or object.
static id vp_bridge_argument_object(JSValue *value) {
    if (value.isUndefined || value.isNull) return nil;
    id object = [value toObject];
    if ([object isKindOfClass:[VPObjCHandle class]]) return ((VPObjCHandle *)object).target;
    return object;
}

/// A method the runtime describes but +methodSignatureForSelector: did not,
/// which happens on a class whose metaclass resolves methods lazily.
static NSMethodSignature *vp_bridge_signature(id target, SEL selector) {
    NSMethodSignature *signature = [target methodSignatureForSelector:selector];
    if (signature) return signature;
    Method method = object_isClass(target) ? class_getClassMethod(target, selector)
                                           : class_getInstanceMethod([target class], selector);
    const char *types = method ? method_getTypeEncoding(method) : NULL;
    return types ? [NSMethodSignature signatureWithObjCTypes:types] : nil;
}

/// One argument slot, large enough for every scalar an invocation takes.
union VPArgumentSlot {
    bool asBool;
    char asChar;
    unsigned char asUnsignedChar;
    short asShort;
    unsigned short asUnsignedShort;
    int asInt;
    unsigned int asUnsignedInt;
    long asLong;
    unsigned long asUnsignedLong;
    long long asLongLong;
    unsigned long long asUnsignedLongLong;
    float asFloat;
    double asDouble;
    void *asPointer;
    const char *asCString;
    Class asClass;
    SEL asSelector;
    __unsafe_unretained id asObject;
};

/// Fill `slot` from `value` for one argument. `holds` keeps anything the
/// invocation borrows a pointer into alive until it returns. False once the
/// context's exception is set.
static bool vp_bridge_fill(union VPArgumentSlot *slot, const char *type, JSValue *value,
                           NSMutableArray *holds, JSContext *context) {
    type = vp_bridge_unqualified(type);
    switch (type[0]) {
    case '@': {
        id object = vp_bridge_argument_object(value);
        if (object) [holds addObject:object];
        slot->asObject = object;
        return true;
    }
    case '#': {
        id object = vp_bridge_argument_object(value);
        if (object && !object_isClass(object)) {
            vp_bridge_throw(context, @"Expected a class argument, got %@", [object class]);
            return false;
        }
        slot->asClass = object;
        return true;
    }
    case ':': {
        NSString *name = [value toString];
        slot->asSelector = name.length ? NSSelectorFromString(name) : NULL;
        return true;
    }
    case '*': {
        if (value.isNull || value.isUndefined) {
            slot->asCString = NULL;
            return true;
        }
        NSString *text = [value toString];
        if (!text) {
            vp_bridge_throw(context, @"Expected a string argument");
            return false;
        }
        [holds addObject:text];
        slot->asCString = text.UTF8String;
        return true;
    }
    case 'B': slot->asBool = [value toBool]; return true;
    case 'c': slot->asChar = (char)[value toInt32]; return true;
    case 'C': slot->asUnsignedChar = (unsigned char)[value toUInt32]; return true;
    case 's': slot->asShort = (short)[value toInt32]; return true;
    case 'S': slot->asUnsignedShort = (unsigned short)[value toUInt32]; return true;
    case 'i': slot->asInt = [value toInt32]; return true;
    case 'I': slot->asUnsignedInt = [value toUInt32]; return true;
    case 'l': slot->asLong = (long)[value toDouble]; return true;
    case 'L': slot->asUnsignedLong = (unsigned long)[value toDouble]; return true;
    case 'q': slot->asLongLong = (long long)[value toDouble]; return true;
    case 'Q': slot->asUnsignedLongLong = (unsigned long long)[value toDouble]; return true;
    case 'f': slot->asFloat = (float)[value toDouble]; return true;
    case 'd': slot->asDouble = [value toDouble]; return true;
    case '^':
        // A script has no way to make a valid pointer, and letting it invent
        // one would only turn a typo into a crash.
        if (value.isNull || value.isUndefined) {
            slot->asPointer = NULL;
            return true;
        }
        vp_bridge_throw(context, @"Only null may be passed for the pointer argument '%s'", type);
        return false;
    default:
        vp_bridge_throw(context, @"Arguments of type '%s' are not supported", type);
        return false;
    }
}

/// Read the return value an invocation left behind.
static JSValue *vp_bridge_return(NSInvocation *invocation, const char *type, SEL selector, JSContext *context) {
    type = vp_bridge_unqualified(type);
    switch (type[0]) {
    case 'v': return [JSValue valueWithUndefinedInContext:context];
    case '@': {
        void *raw = NULL;
        [invocation getReturnValue:&raw];
        id object = vp_bridge_returns_retained(selector) ? (__bridge_transfer id)raw : (__bridge id)raw;
        if (object && vp_bridge_returns_placeholder(selector)) {
            return [JSValue valueWithObject:[VPObjCHandle handleFor:object] inContext:context];
        }
        return vp_bridge_result(object, context);
    }
    case '#': {
        Class result = Nil;
        [invocation getReturnValue:&result];
        return vp_bridge_result(result, context);
    }
    case ':': {
        SEL result = NULL;
        [invocation getReturnValue:&result];
        return result ? [JSValue valueWithObject:NSStringFromSelector(result) inContext:context]
                      : [JSValue valueWithNullInContext:context];
    }
    case '*': {
        const char *result = NULL;
        [invocation getReturnValue:&result];
        return result ? [JSValue valueWithObject:@(result) inContext:context]
                      : [JSValue valueWithNullInContext:context];
    }
#define VP_BRIDGE_SCALAR_RETURN(encoding, kind)                             \
    case encoding: {                                                        \
        kind result = 0;                                                    \
        [invocation getReturnValue:&result];                                \
        return [JSValue valueWithDouble:(double)result inContext:context];  \
    }
        VP_BRIDGE_SCALAR_RETURN('c', char)
        VP_BRIDGE_SCALAR_RETURN('C', unsigned char)
        VP_BRIDGE_SCALAR_RETURN('s', short)
        VP_BRIDGE_SCALAR_RETURN('S', unsigned short)
        VP_BRIDGE_SCALAR_RETURN('i', int)
        VP_BRIDGE_SCALAR_RETURN('I', unsigned int)
        VP_BRIDGE_SCALAR_RETURN('l', long)
        VP_BRIDGE_SCALAR_RETURN('L', unsigned long)
        VP_BRIDGE_SCALAR_RETURN('q', long long)
        VP_BRIDGE_SCALAR_RETURN('Q', unsigned long long)
        VP_BRIDGE_SCALAR_RETURN('f', float)
        VP_BRIDGE_SCALAR_RETURN('d', double)
#undef VP_BRIDGE_SCALAR_RETURN
    case 'B': {
        bool result = false;
        [invocation getReturnValue:&result];
        return [JSValue valueWithBool:result inContext:context];
    }
    case '^': {
        void *result = NULL;
        [invocation getReturnValue:&result];
        // The address is worth reading; nothing can be done with it here.
        return result ? [JSValue valueWithDouble:(double)(uintptr_t)result inContext:context]
                      : [JSValue valueWithNullInContext:context];
    }
    default:
        vp_bridge_throw(context, @"Return values of type '%s' are not supported", type);
        return [JSValue valueWithUndefinedInContext:context];
    }
}

- (JSValue *)sendSelectorNamed:(NSString *)name arguments:(JSValue *)arguments {
    JSContext *context = [JSContext currentContext];
    JSValue *undefined = [JSValue valueWithUndefinedInContext:context];
    SEL selector = name.length ? NSSelectorFromString(name) : NULL;
    if (!selector) {
        vp_bridge_throw(context, @"A selector is required");
        return undefined;
    }
    NSMethodSignature *signature = vp_bridge_signature(_target, selector);
    if (!signature) {
        vp_bridge_throw(context, @"%@ does not respond to %@", self.className, name);
        return undefined;
    }

    NSUInteger expected = signature.numberOfArguments - 2;
    NSUInteger given = [arguments[@"length"] toUInt32];
    if (given != expected) {
        vp_bridge_throw(context, @"%@ takes %lu argument%s, got %lu", name,
                        (unsigned long)expected, expected == 1 ? "" : "s", (unsigned long)given);
        return undefined;
    }

    NSInvocation *invocation = [NSInvocation invocationWithMethodSignature:signature];
    invocation.selector = selector;
    invocation.target = _target;
    NSMutableArray *holds = [NSMutableArray array];
    union VPArgumentSlot slots[expected > 0 ? expected : 1];
    for (NSUInteger index = 0; index < expected; index++) {
        const char *type = [signature getArgumentTypeAtIndex:index + 2];
        if (!vp_bridge_fill(&slots[index], type, [arguments valueAtIndex:(NSUInteger)index], holds, context)) {
            return undefined;
        }
        [invocation setArgument:&slots[index] atIndex:(NSInteger)(index + 2)];
    }

    @try {
        [invocation invoke];
    } @catch (NSException *exception) {
        vp_bridge_throw(context, @"%@ raised %@: %@", name, exception.name, exception.reason ?: @"");
        return undefined;
    }
    if (signature.methodReturnLength == 0) return undefined;
    return vp_bridge_return(invocation, signature.methodReturnType, selector, context);
}

@end

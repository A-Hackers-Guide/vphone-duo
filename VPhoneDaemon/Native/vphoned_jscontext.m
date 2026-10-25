#import "vphoned_jsbridge.h"
#import "vphoned_session.h"

#include <sys/stat.h>
#include <unistd.h>

// The session's JavaScript context. JavaScriptCore is the one scripting
// runtime already on an iOS and a tvOS guest, so a session needs nothing
// installed; watchOS has no public copy, which is why vphoned links it
// weakly and every entry point here checks availability first.

static JSContext *vp_context;
static JSValue *vp_thrown;
static NSMutableString *vp_output;
static bool vp_capturing;
static char *(*vp_api_handler)(const char *);

/// What one script may collect before its output stops growing. A runaway
/// loop must not take the session's memory with it.
static const NSUInteger vp_output_limit = 1 << 20;

bool vp_js_available(void) {
    return NSClassFromString(@"JSContext") != nil;
}

void vp_js_set_api_handler(char *(*handler)(const char *request)) {
    vp_api_handler = handler;
}

// MARK: - Output

static void vp_js_write(int descriptor, NSString *text) {
    if (!text.length) return;
    if (vp_capturing) {
        if (vp_output.length < vp_output_limit) [vp_output appendString:text];
        return;
    }
    FILE *stream = descriptor == 2 ? stderr : stdout;
    fputs(text.UTF8String ?: "", stream);
    fflush(stream);
}

void vp_js_capture_output(bool enabled) {
    vp_capturing = enabled;
    if (enabled && !vp_output) vp_output = [NSMutableString string];
}

char *vp_js_take_output(void) {
    NSString *text = vp_output ?: @"";
    char *copy = strdup(text.UTF8String ?: "");
    [vp_output setString:@""];
    return copy;
}

// MARK: - Globals

static void vp_js_throw(NSString *format, ...) {
    va_list arguments;
    va_start(arguments, format);
    NSString *message = [[NSString alloc] initWithFormat:format arguments:arguments];
    va_end(arguments);
    JSContext *context = [JSContext currentContext] ?: vp_context;
    context.exception = [JSValue valueWithNewErrorFromMessage:message inContext:context];
}

static NSString *vp_js_posix_error(NSString *call, NSString *path) {
    return [NSString stringWithFormat:@"%@(%@): %s", call, path, strerror(errno)];
}

static void vp_js_install_files(JSContext *context) {
    context[@"__fs_list"] = ^id(NSString *path) {
        NSError *failure = nil;
        NSArray *names = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:path ?: @"" error:&failure];
        if (!names) {
            vp_js_throw(@"%@", failure.localizedDescription ?: @"Could not list the directory");
            return nil;
        }
        return [names sortedArrayUsingSelector:@selector(compare:)];
    };

    context[@"__fs_read"] = ^id(NSString *path) {
        NSError *failure = nil;
        NSData *data = [NSData dataWithContentsOfFile:path ?: @"" options:0 error:&failure];
        if (!data) {
            vp_js_throw(@"%@", failure.localizedDescription ?: @"Could not read the file");
            return nil;
        }
        NSString *text = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
        if (!text) {
            vp_js_throw(@"%@ is not UTF-8 text; read it with the files API instead", path);
            return nil;
        }
        return text;
    };

    context[@"__fs_write"] = ^id(NSString *path, NSString *text) {
        NSData *data = [text ?: @"" dataUsingEncoding:NSUTF8StringEncoding];
        NSError *failure = nil;
        if (![data writeToFile:path ?: @"" options:NSDataWritingAtomic error:&failure]) {
            vp_js_throw(@"%@", failure.localizedDescription ?: @"Could not write the file");
            return nil;
        }
        return @(data.length);
    };

    context[@"__fs_stat"] = ^id(NSString *path) {
        struct stat info;
        if (lstat(path.fileSystemRepresentation ?: "", &info) != 0) {
            vp_js_throw(@"%@", vp_js_posix_error(@"lstat", path));
            return nil;
        }
        NSString *kind = @"other";
        switch (info.st_mode & S_IFMT) {
        case S_IFREG: kind = @"file"; break;
        case S_IFDIR: kind = @"directory"; break;
        case S_IFLNK: kind = @"symlink"; break;
        default: break;
        }
        return @{
            @"type": kind,
            @"size": @(info.st_size),
            @"mode": [NSString stringWithFormat:@"%o", info.st_mode & 07777],
            @"uid": @(info.st_uid),
            @"gid": @(info.st_gid),
            @"mtime": @(info.st_mtimespec.tv_sec),
        };
    };
}

static void vp_js_install_process(JSContext *context) {
    context[@"__proc_run"] = ^id(NSString *path, id arguments, id input) {
        NSArray *list = [arguments isKindOfClass:[NSArray class]] ? arguments : @[];
        // The argument vector is built on the stack, so a script must not be
        // the one deciding how large it is.
        if (list.count > 1024) {
            vp_js_throw(@"proc.run takes at most 1024 arguments, got %lu", (unsigned long)list.count);
            return nil;
        }
        NSMutableArray<NSString *> *words = [NSMutableArray arrayWithObject:path ?: @""];
        for (id argument in list) [words addObject:[argument description]];
        const char *argv[words.count + 1];
        for (NSUInteger index = 0; index < words.count; index++) {
            argv[index] = words[index].UTF8String;
        }
        argv[words.count] = NULL;

        NSString *text = [input isKindOfClass:[NSString class]] ? input : nil;
        int status = 0;
        char *output = NULL;
        char *errors = NULL;
        int failure = vp_spawn_collect(path.fileSystemRepresentation ?: "", argv,
                                       text ? text.UTF8String : NULL, &status, &output, &errors);
        if (failure != 0) {
            vp_js_throw(@"%@: %s", path, strerror(failure));
            free(output);
            free(errors);
            return nil;
        }
        NSDictionary *result = @{
            @"status": @(WIFEXITED(status) ? WEXITSTATUS(status) : -1),
            @"signal": WIFSIGNALED(status) ? @(WTERMSIG(status)) : [NSNull null],
            @"stdout": @(output ?: ""),
            @"stderr": @(errors ?: ""),
        };
        free(output);
        free(errors);
        return result;
    };

    context[@"__sleep"] = ^(double milliseconds) {
        if (milliseconds > 0 && milliseconds < 600000) usleep((useconds_t)(milliseconds * 1000));
    };

    context[@"__exit"] = ^(double code) {
        exit((int)code);
    };
}

static void vp_js_install_api(JSContext *context) {
    context[@"__api"] = ^id(NSString *method, id parameters) {
        if (!vp_api_handler) {
            vp_js_throw(@"This session has no API handler");
            return nil;
        }
        NSDictionary *params = [parameters isKindOfClass:[NSDictionary class]] ? parameters : @{};
        NSDictionary *request = @{@"method": method ?: @"", @"params": params};
        NSData *encoded = [NSJSONSerialization dataWithJSONObject:request options:0 error:nil];
        if (!encoded) {
            vp_js_throw(@"The parameters of %@ are not JSON", method);
            return nil;
        }
        NSMutableData *terminated = [encoded mutableCopy];
        [terminated appendBytes:"" length:1];
        char *reply = vp_api_handler(terminated.bytes);
        if (!reply) {
            vp_js_throw(@"%@ returned nothing", method);
            return nil;
        }
        NSData *data = [NSData dataWithBytesNoCopy:reply length:strlen(reply) freeWhenDone:YES];
        NSDictionary *object = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
        if (![object isKindOfClass:[NSDictionary class]]) {
            vp_js_throw(@"%@ returned a malformed reply", method);
            return nil;
        }
        NSDictionary *failure = object[@"error"];
        if ([failure isKindOfClass:[NSDictionary class]]) {
            vp_js_throw(@"%@: %@", failure[@"code"] ?: @"error", failure[@"message"] ?: @"failed");
            return nil;
        }
        return object[@"result"] ?: [NSNull null];
    };
}

/// The ergonomic layer, written in the language it serves: a proxy per ObjC
/// object so a script calls methods by name, and `console`, `fs`, `proc` and
/// `api` over the primitives installed above. A method name's underscores
/// become colons (`setValue_forKey_`), or a bare name takes one colon per
/// argument; a name that already has colons is used as it stands.
static NSString *const vp_js_prelude =
    @"(function (global) {\n"
    @"  'use strict';\n"
    @"  function describe(value) {\n"
    @"    if (typeof value === 'string') return value;\n"
    @"    if (value === null) return 'null';\n"
    @"    if (value === undefined) return 'undefined';\n"
    @"    if (typeof value === 'function') return String(value);\n"
    @"    if (typeof value === 'object') {\n"
    @"      if (value.objcHandle === true || value.$handle !== undefined) return String(value);\n"
    @"      try { return JSON.stringify(value); } catch (error) { return String(value); }\n"
    @"    }\n"
    @"    return String(value);\n"
    @"  }\n"
    @"  function selectorFor(name, count) {\n"
    @"    if (name.indexOf(':') >= 0) return name;\n"
    @"    if (name.indexOf('_') >= 0) return name.replace(/_/g, ':');\n"
    @"    return count > 0 ? name + ':'.repeat(count) : name;\n"
    @"  }\n"
    @"  function unwrap(value) {\n"
    @"    if (value !== null && typeof value === 'object' && value.$handle !== undefined) return value.$handle;\n"
    @"    return value;\n"
    @"  }\n"
    @"  function box(value) {\n"
    @"    if (value !== null && typeof value === 'object' && value.objcHandle === true) return wrap(value);\n"
    @"    return value;\n"
    @"  }\n"
    @"  function wrap(handle) {\n"
    @"    return new Proxy({}, {\n"
    @"      get: function (_, property) {\n"
    @"        if (typeof property === 'symbol') {\n"
    @"          if (property === Symbol.toPrimitive) return function () { return handle.toString(); };\n"
    @"          if (property === Symbol.toStringTag) return handle.className;\n"
    @"          return undefined;\n"
    @"        }\n"
    @"        if (property === '$handle') return handle;\n"
    @"        if (property === '$class') return handle.className;\n"
    @"        if (property === '$isClass') return handle.isClassHandle;\n"
    @"        if (property === '$value') return handle.plainValue();\n"
    @"        if (property === 'toString' || property === 'inspect') {\n"
    @"          return function () { return handle.toString(); };\n"
    @"        }\n"
    @"        return function () {\n"
    @"          var args = Array.prototype.slice.call(arguments).map(unwrap);\n"
    @"          return box(handle.send(selectorFor(property, args.length), args));\n"
    @"        };\n"
    @"      },\n"
    @"    });\n"
    @"  }\n"
    @"  var ObjC = {\n"
    @"    use: function (name) {\n"
    @"      var handle = global.__objc_class(name);\n"
    @"      if (!handle) throw new Error('No ObjC class named ' + name);\n"
    @"      return wrap(handle);\n"
    @"    },\n"
    @"    wrap: box,\n"
    @"    classes: new Proxy({}, {\n"
    @"      get: function (_, name) { return typeof name === 'string' ? ObjC.use(name) : undefined; },\n"
    @"    }),\n"
    @"  };\n"
    @"  function writeLine(descriptor, values) {\n"
    @"    global.__write(descriptor, values.map(describe).join(' ') + '\\n');\n"
    @"  }\n"
    @"  function toList(values) { return Array.prototype.slice.call(values); }\n"
    @"  global.console = {\n"
    @"    log: function () { writeLine(1, toList(arguments)); },\n"
    @"    info: function () { writeLine(1, toList(arguments)); },\n"
    @"    warn: function () { writeLine(2, toList(arguments)); },\n"
    @"    error: function () { writeLine(2, toList(arguments)); },\n"
    @"  };\n"
    @"  global.print = global.console.log;\n"
    @"  global.fs = {\n"
    @"    ls: function (path) { return global.__fs_list(path); },\n"
    @"    read: function (path) { return global.__fs_read(path); },\n"
    @"    write: function (path, text) { return global.__fs_write(path, text); },\n"
    @"    stat: function (path) { return global.__fs_stat(path); },\n"
    @"  };\n"
    @"  global.proc = {\n"
    @"    run: function (path, args, input) {\n"
    @"      return global.__proc_run(path, args || [], input === undefined ? null : input);\n"
    @"    },\n"
    @"  };\n"
    @"  global.api = function (method, params) { return global.__api(method, params || {}); };\n"
    @"  global.sleep = function (milliseconds) { global.__sleep(milliseconds); };\n"
    @"  global.exit = function (code) { global.__exit(code === undefined ? 0 : code); };\n"
    @"  global.ObjC = ObjC;\n"
    @"  global.__describe = describe;\n"
    @"})(this);\n";

bool vp_js_start(void) {
    if (vp_context) return true;
    if (!vp_js_available()) return false;
    JSContext *context = [[JSContext alloc] init];
    if (!context) return false;
    context.name = @"vphoned";
    context.exceptionHandler = ^(JSContext *raising, JSValue *exception) {
        (void)raising;
        vp_thrown = exception;
    };

    context[@"__write"] = ^(double descriptor, NSString *text) {
        vp_js_write((int)descriptor, text ?: @"");
    };
    context[@"__objc_class"] = ^id(NSString *name) {
        Class owner = name.length ? NSClassFromString(name) : Nil;
        return owner ? [VPObjCHandle handleFor:owner] : nil;
    };
    vp_js_install_files(context);
    vp_js_install_process(context);
    vp_js_install_api(context);

    vp_thrown = nil;
    [context evaluateScript:vp_js_prelude withSourceURL:[NSURL URLWithString:@"vphoned://prelude.js"]];
    if (vp_thrown) {
        NSLog(@"vphoned session: the prelude failed: %@", [vp_thrown toString]);
        vp_thrown = nil;
        return false;
    }
    vp_context = context;
    return true;
}

// MARK: - Evaluation

static NSString *vp_js_describe(JSValue *value) {
    if (!value) return @"undefined";
    JSValue *describe = vp_context[@"__describe"];
    if (describe.isObject) {
        JSValue *text = [describe callWithArguments:@[value]];
        if (text.isString) return [text toString];
    }
    return [value toString] ?: @"undefined";
}

/// An uncaught error, with the stack JSC recorded when there is one: a script
/// in a guest cannot be stepped through, so the trace is all there is.
static NSString *vp_js_describe_exception(JSValue *exception) {
    NSString *message = [exception toString] ?: @"Unknown error";
    if (!exception.isObject) return message;
    JSValue *stack = exception[@"stack"];
    if (!stack.isString) return message;
    NSString *trace = [[stack toString] stringByTrimmingCharactersInSet:
                                           [NSCharacterSet whitespaceAndNewlineCharacterSet]];
    return trace.length ? [NSString stringWithFormat:@"%@\n%@", message, trace] : message;
}

char *vp_js_evaluate(const char *source, char **error) {
    if (error) *error = NULL;
    if (!vp_context && !vp_js_start()) {
        if (error) *error = strdup("This guest has no JavaScriptCore");
        return NULL;
    }
    vp_thrown = nil;
    JSValue *value = [vp_context evaluateScript:@(source ?: "")
                                  withSourceURL:[NSURL URLWithString:@"vphoned://session.js"]];
    if (vp_thrown) {
        JSValue *exception = vp_thrown;
        vp_thrown = nil;
        if (error) *error = strdup(vp_js_describe_exception(exception).UTF8String ?: "Unknown error");
        return NULL;
    }
    return strdup(vp_js_describe(value).UTF8String ?: "undefined");
}

#import "vphoned_session.h"

#import <Foundation/Foundation.h>

#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/wait.h>
#include <unistd.h>

// Checks the scripting session on the Mac: the JavaScript runtime, the ObjC
// bridge, the session's own process modes, and the pseudo-terminal the worker
// opens for an interactive one. No guest is needed, and because this test
// binary answers `--session` the way vphoned does, the spawning paths are
// exercised for real rather than stubbed. `run-session-tests.sh` builds it.

static int checks;
static int failures;

static void expect(bool condition, const char *format, ...) {
    checks++;
    if (condition) return;
    failures++;
    va_list arguments;
    va_start(arguments, format);
    fputs("FAIL: ", stderr);
    vfprintf(stderr, format, arguments);
    fputc('\n', stderr);
    va_end(arguments);
}

// MARK: - Evaluation Helpers

/// The described value of `source`, or nil with the error reported.
static NSString *evaluate(const char *source) {
    char *failure = NULL;
    char *described = vp_js_evaluate(source, &failure);
    if (!described) {
        NSString *message = @(failure ?: "Unknown error");
        free(failure);
        expect(false, "%s threw %s", source, message.UTF8String);
        return nil;
    }
    NSString *text = @(described);
    free(described);
    return text;
}

static void expectValue(const char *source, NSString *expected) {
    NSString *actual = evaluate(source);
    if (!actual) return;
    expect([actual isEqualToString:expected], "%s: expected %s, got %s",
           source, expected.UTF8String, actual.UTF8String);
}

/// The error message `source` raised, or nil when it did not raise one.
static NSString *expectThrows(const char *source) {
    char *failure = NULL;
    char *described = vp_js_evaluate(source, &failure);
    checks++;
    if (described) {
        failures++;
        fprintf(stderr, "FAIL: %s should have thrown, returned %s\n", source, described);
        free(described);
        return nil;
    }
    NSString *message = @(failure ?: "");
    free(failure);
    return message;
}

static void expectThrowsContaining(const char *source, NSString *fragment) {
    NSString *message = expectThrows(source);
    if (!message) return;
    expect([message containsString:fragment], "%s: expected an error naming %s, got %s",
           source, fragment.UTF8String, message.UTF8String);
}

// MARK: - The Runtime

static void runtimeBasics(void) {
    expect(vp_js_available(), "JavaScriptCore is available on the Mac");
    expect(vp_js_start(), "the context starts");
    expect(vp_js_start(), "starting twice is harmless");

    expectValue("1 + 2", @"3");
    expectValue("'a' + 'b'", @"ab");
    expectValue("[1, 2, 3].map(function (n) { return n * 2; })", @"[2,4,6]");
    expectValue("JSON.stringify({a: 1})", @"{\"a\":1}");
    expectValue("({a: 1, b: [2]})", @"{\"a\":1,\"b\":[2]}");
    expectValue("null", @"null");
    expectValue("undefined", @"undefined");
    expectValue("var x = 5; x * x", @"25");
    expectValue("x + 1", @"6");

    expectThrowsContaining("throw new Error('boom')", @"boom");
    expectThrowsContaining("function (", @"SyntaxError");
    expectThrowsContaining("nothingHere()", @"nothingHere");
    // The trace is all a script in a guest has, so it must survive.
    NSString *trace = expectThrows("function inner() { throw new Error('deep'); }\ninner()");
    expect(!trace || [trace containsString:@"inner"], "the stack names the function that threw");
}

static void outputCapture(void) {
    vp_js_capture_output(true);
    expectValue("console.log('one', 2, {a: 3}); 'done'", @"done");
    char *output = vp_js_take_output();
    expect(strcmp(output, "one 2 {\"a\":3}\n") == 0, "console.log described each value: %s", output);
    free(output);

    expectValue("console.error('to stderr'); 1", @"1");
    output = vp_js_take_output();
    expect(strcmp(output, "to stderr\n") == 0, "stderr is collected too: %s", output);
    free(output);

    output = vp_js_take_output();
    expect(strcmp(output, "") == 0, "taking the output clears it");
    free(output);
    vp_js_capture_output(false);
}

// MARK: - The ObjC Bridge

static void bridgeBasics(void) {
    expectValue("typeof ObjC.use('NSProcessInfo')", @"object");
    expectValue("ObjC.use('NSProcessInfo').$isClass", @"true");
    expectThrowsContaining("ObjC.use('NoSuchClassHere')", @"No ObjC class");

    // A class method, then an instance method on what it returned.
    NSString *name = evaluate("ObjC.use('NSProcessInfo').processInfo().processName()");
    expect(name.length > 0, "processName returned a string: %s", name.UTF8String);
    expectValue("typeof ObjC.classes.NSProcessInfo.processInfo().processName()", @"string");

    // JSC's own types come back as themselves, not as handles.
    expectValue("ObjC.use('NSString').stringWithUTF8String_('hi')", @"hi");
    expectValue("typeof ObjC.use('NSString').stringWithUTF8String_('hi')", @"string");
    expectValue("ObjC.use('NSNumber').numberWithInt_(7) + 1", @"8");

    // An object the bridge has to keep as a handle.
    expectValue("var list = ObjC.use('NSMutableArray').array(); list.count()", @"0");
    expectValue("list.addObject_('first'); list.addObject_('second'); list.count()", @"2");
    expectValue("list.objectAtIndex_(1)", @"second");
    expectValue("list.componentsJoinedByString_('-')", @"first-second");
    // A collection stays an object, and converts only when asked to.
    expectValue("list.$value.join(',')", @"first,second");
    expectValue("Array.isArray(list.$value)", @"true");
    expectValue("typeof list.$handle", @"object");
    expectValue("list.$class", @"__NSArrayM");

    // A written-out selector, and an ObjC object as an argument.
    expectValue("var other = ObjC.use('NSMutableArray').array();"
                "other['addObjectsFromArray:'](list); other.count()",
                @"2");
    expectValue("var map = ObjC.use('NSMutableDictionary').dictionary();"
                "map.setValue_forKey_('v', 'k'); map.objectForKey_('k')",
                @"v");
    expectValue("JSON.stringify(map.$value)", @"{\"k\":\"v\"}");

    // Scalars in both directions.
    expectValue("ObjC.use('NSFileManager').defaultManager().fileExistsAtPath_('/')", @"true");
    expectValue("ObjC.use('NSFileManager').defaultManager().fileExistsAtPath_('/no/such/path')", @"false");
    expectValue("ObjC.use('NSString').stringWithUTF8String_('abc').length", @"3");

    // String conversion goes through the object's own description.
    expectValue("String(ObjC.use('NSMutableArray').array())", @"(\n)");

    // The alloc/init/copy families hand back an object the caller owns. Each
    // of these would over-release and take the process with it if the bridge
    // claimed ownership it had not been given, or leak if it missed one.
    expectValue("ObjC.use('NSMutableArray').alloc().init().count()", @"0");
    expectValue("ObjC.use('NSString').alloc()['initWithUTF8String:']('owned')", @"owned");
    expectValue("var copied = list.mutableCopy(); copied.addObject_('third'); copied.count()", @"3");
    expectValue("list.count()", @"2");
    expectValue("ObjC.use('NSMutableArray').array().copy().$class", @"__NSArray0");
    for (int round = 0; round < 200; round++) {
        char *described = vp_js_evaluate("ObjC.use('NSMutableDictionary').alloc().init().count()", NULL);
        free(described);
    }
    expect(true, "two hundred owned objects came and went without a crash");
}

static void bridgeRefusals(void) {
    expectThrowsContaining("ObjC.use('NSProcessInfo').processInfo().noSuchMethodAtAll()", @"does not respond to");
    expectThrowsContaining("ObjC.use('NSMutableArray').array().addObject_('a', 'b')", @"takes 1 argument");
    expectThrowsContaining("ObjC.use('NSMutableArray').array().addObject_()", @"takes 1 argument");
    // A struct return would need its layout read out of the encoding; the
    // refusal has to name the type so the limit is obvious from the message.
    expectThrowsContaining("ObjC.use('NSProcessInfo').processInfo().operatingSystemVersion()", @"not supported");
    // Raising rather than crashing is the whole point of the @try around invoke.
    expectThrowsContaining("ObjC.use('NSMutableArray').array().objectAtIndex_(4)", @"raised");
    expectThrowsContaining("ObjC.use('NSMutableArray').array().addObject_(null)", @"raised");
}

// MARK: - Files, Programs and the API

static void filesAndPrograms(void) {
    NSString *directory = [NSTemporaryDirectory() stringByAppendingPathComponent:@"vphone-session-tests"];
    [[NSFileManager defaultManager] createDirectoryAtPath:directory
                             withIntermediateDirectories:YES attributes:nil error:nil];
    NSString *file = [directory stringByAppendingPathComponent:@"probe.txt"];
    vp_js_capture_output(true);

    NSString *source = [NSString stringWithFormat:@"fs.write('%@', 'written by a session')", file];
    expectValue(source.UTF8String, @"20");
    source = [NSString stringWithFormat:@"fs.read('%@')", file];
    expectValue(source.UTF8String, @"written by a session");
    source = [NSString stringWithFormat:@"fs.stat('%@').type", file];
    expectValue(source.UTF8String, @"file");
    source = [NSString stringWithFormat:@"fs.stat('%@').size", file];
    expectValue(source.UTF8String, @"20");
    source = [NSString stringWithFormat:@"fs.ls('%@').join(',')", directory];
    expectValue(source.UTF8String, @"probe.txt");
    (void)expectThrows("fs.read('/no/such/file/at/all')");
    (void)expectThrows("fs.ls('/no/such/directory')");

    expectValue("proc.run('/bin/echo', ['hello']).stdout", @"hello\n");
    expectValue("proc.run('/bin/echo', ['hello']).status", @"0");
    expectValue("proc.run('/bin/sh', ['-c', 'exit 3']).status", @"3");
    expectValue("proc.run('/bin/cat', [], 'through stdin').stdout", @"through stdin");
    expectValue("proc.run('/bin/sh', ['-c', 'echo oops >&2']).stderr", @"oops\n");
    (void)expectThrows("proc.run('/no/such/program')");
    // The argument vector is a stack array, so its size is the bridge's to
    // decide and not the script's.
    expectThrowsContaining("proc.run('/bin/echo', new Array(2000).fill('x'))",
                           @"at most 1024 arguments");

    vp_js_capture_output(false);
    [[NSFileManager defaultManager] removeItemAtPath:directory error:nil];
}

static char *answerAPI(const char *request) {
    if (strstr(request, "\"method\":\"boom\"")) {
        return strdup("{\"type\":\"response\",\"error\":{\"code\":\"invalid_operation\",\"message\":\"no\"}}");
    }
    if (strstr(request, "\"method\":\"echo\"")) {
        return strdup("{\"type\":\"response\",\"result\":{\"saw\":\"echo\"}}");
    }
    return strdup("{\"type\":\"response\",\"result\":null}");
}

static void guestAPI(void) {
    expectThrowsContaining("api('device.snapshot')", @"no API handler");
    vp_js_set_api_handler(answerAPI);
    expectValue("api('echo').saw", @"echo");
    expectValue("api('echo', {with: 1}).saw", @"echo");
    expectThrowsContaining("api('boom')", @"invalid_operation");
    expectValue("api('other')", @"null");
    vp_js_set_api_handler(NULL);
}

// MARK: - Source Completeness

static void sourceCompleteness(void) {
    expect(!vp_js_source_is_incomplete("1 + 1"), "a statement is complete");
    expect(!vp_js_source_is_incomplete(""), "nothing is complete");
    expect(vp_js_source_is_incomplete("function f() {"), "an open brace continues");
    expect(!vp_js_source_is_incomplete("function f() {}"), "a closed brace does not");
    expect(vp_js_source_is_incomplete("[1, 2,"), "an open bracket continues");
    expect(vp_js_source_is_incomplete("f("), "an open call continues");
    expect(!vp_js_source_is_incomplete("'a {'"), "a brace inside a string is text");
    expect(!vp_js_source_is_incomplete("\"}\""), "and so is one in double quotes");
    expect(vp_js_source_is_incomplete("`line"), "a template literal spans lines");
    expect(!vp_js_source_is_incomplete("`line`"), "a closed one does not");
    expect(!vp_js_source_is_incomplete("1 // {"), "a line comment ends at the newline");
    expect(vp_js_source_is_incomplete("1 /* {"), "a block comment continues");
    expect(!vp_js_source_is_incomplete("1 /* { */"), "a closed block comment does not");
    expect(!vp_js_source_is_incomplete("'it\\'s'"), "an escaped quote stays inside the string");
    expect(!vp_js_source_is_incomplete("}"), "a stray close brace is left to the parser");
    expect(!vp_js_source_is_incomplete("/\\{/.test('{')"),
           "a brace inside a regular expression is not an open one");
    expect(!vp_js_source_is_incomplete("var r = /['\"]/;"),
           "nor is a quote inside one the start of a string");
    expect(!vp_js_source_is_incomplete("return /\\{/.test(s)"),
           "a regular expression may follow a keyword");
    expect(!vp_js_source_is_incomplete("a / b / c"), "division is not a regular expression");
    expect(vp_js_source_is_incomplete("var x = (a / b"),
           "an open call continues past a division");
    expect(vp_js_source_is_incomplete("var r = /[{/"),
           "an unterminated regular expression is read as a division");
}

// MARK: - Descriptor Accounting

/// How many descriptors this process holds. A session's pipes and terminal
/// belong to the worker, which is long-lived: one left behind for every
/// script that timed out ends in a daemon that can no longer accept a
/// connection.
static int openDescriptors(void) {
    int count = 0;
    for (int descriptor = 0; descriptor < 256; descriptor++) {
        if (fcntl(descriptor, F_GETFD) != -1) count++;
    }
    return count;
}

static void descriptorAccounting(void) {
    int status = -1;
    // One first, so what follows counts the descriptors a session opens and
    // not whatever the runtime opens once on its way up.
    free(vp_session_evaluate("1", 20, &status));

    int before = openDescriptors();
    for (int round = 0; round < 3; round++) {
        free(vp_session_evaluate("1 + 1", 20, &status));
    }
    expect(openDescriptors() == before, "an answered script leaves no descriptor behind");

    for (int round = 0; round < 3; round++) {
        char *reply = vp_session_evaluate("for (;;) {}", 0.3, &status);
        expect(reply == NULL, "a script that outran its timeout has no answer");
        free(reply);
    }
    expect(openDescriptors() == before, "nor does one that timed out");

    const char *argv[] = {"/bin/echo", "ok", NULL};
    for (int round = 0; round < 3; round++) {
        char *output = NULL;
        char *errors = NULL;
        vp_spawn_collect("/bin/echo", argv, NULL, &status, &output, &errors);
        free(output);
        free(errors);
    }
    expect(openDescriptors() == before, "nor does a program a script ran");

    pid_t session = -1;
    int master = vp_session_open(NULL, 80, 24, &session);
    expect(master >= 0, "a terminal session opened: %s", master >= 0 ? "yes" : strerror(errno));
    if (master >= 0) {
        vp_session_close(master, session, 2);
        expect(openDescriptors() == before, "nor does an interactive session that has ended");
    }
}

// MARK: - Session Processes

/// What `descriptor` has to say, up to `timeout` seconds of silence to begin
/// with and a quarter of a second once something has arrived. A terminal is
/// never closed by the side that is still talking, so quiet is the only end
/// of a reply there is.
static NSString *drain(int descriptor, double timeout) {
    NSMutableData *collected = [NSMutableData data];
    for (;;) {
        int wait_ms = collected.length ? 250 : (int)(timeout * 1000);
        struct pollfd watched = {.fd = descriptor, .events = POLLIN};
        int ready = poll(&watched, 1, wait_ms);
        if (ready < 0 && errno == EINTR) continue;
        if (ready <= 0) break;
        char bytes[4096];
        ssize_t count = read(descriptor, bytes, sizeof(bytes));
        if (count > 0) {
            [collected appendBytes:bytes length:(NSUInteger)count];
            continue;
        }
        // A pseudo-terminal whose child has gone reports EIO, not end of file.
        if (count < 0 && errno == EINTR) continue;
        break;
    }
    return [[NSString alloc] initWithData:collected encoding:NSUTF8StringEncoding] ?: @"";
}

static void oneShotEvaluation(void) {
    int status = -1;
    char *reply = vp_session_evaluate("1 + 1", 20, &status);
    expect(reply != NULL, "the session answered: %s", reply ? "yes" : strerror(errno));
    if (reply) {
        NSData *data = [@(reply) dataUsingEncoding:NSUTF8StringEncoding];
        NSDictionary *object = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
        expect([object isKindOfClass:[NSDictionary class]], "the reply is a JSON object: %s", reply);
        expect([object[@"ok"] boolValue], "the evaluation succeeded: %s", reply);
        expect([object[@"result"] isEqualToString:@"2"], "1 + 1 is 2: %s", reply);
        expect([object[@"output"] isEqualToString:@""], "nothing was printed: %s", reply);
        expect(WIFEXITED(status) && WEXITSTATUS(status) == 0, "the session exited cleanly");
        free(reply);
    }

    reply = vp_session_evaluate("console.log('printed'); 'value'", 20, &status);
    expect(reply != NULL, "the session answered a printing script");
    if (reply) {
        NSDictionary *object = [NSJSONSerialization JSONObjectWithData:
                                                       [@(reply) dataUsingEncoding:NSUTF8StringEncoding]
                                                              options:0 error:nil];
        expect([object[@"result"] isEqualToString:@"value"], "the value came back: %s", reply);
        expect([object[@"output"] isEqualToString:@"printed\n"], "so did the output: %s", reply);
        free(reply);
    }

    reply = vp_session_evaluate("throw new Error('from a session')", 20, &status);
    if (reply) {
        NSDictionary *object = [NSJSONSerialization JSONObjectWithData:
                                                       [@(reply) dataUsingEncoding:NSUTF8StringEncoding]
                                                              options:0 error:nil];
        expect(![object[@"ok"] boolValue], "a throwing script is not ok: %s", reply);
        expect([object[@"error"] containsString:@"from a session"], "the error came back: %s", reply);
        free(reply);
    }

    // The reason a session is its own process: this one dies on a signal, and
    // the parent reports it rather than going down with it.
    reply = vp_session_evaluate(
        "var pid = ObjC.use('NSProcessInfo').processInfo().processIdentifier();"
        "proc.run('/bin/sh', ['-c', 'kill -ABRT ' + pid]); 'never reached'",
        20, &status);
    expect(WIFSIGNALED(status) && WTERMSIG(status) == SIGABRT,
           "the session died on the signal, status %d", status);
    expect(!reply || strstr(reply, "never reached") == NULL, "and answered nothing");
    free(reply);

    // A script that never returns is killed, and the timeout is reported.
    double started = (double)time(NULL);
    reply = vp_session_evaluate("for (;;) {}", 2, &status);
    expect(reply == NULL && errno == ETIMEDOUT, "a runaway script times out");
    expect((double)time(NULL) - started < 10, "and is killed near its deadline");
    free(reply);
}

static void interactiveSession(void) {
    pid_t child = -1;
    int master = vp_session_open(NULL, 100, 40, &child);
    expect(master >= 0, "the REPL opened: %s", master >= 0 ? "yes" : strerror(errno));
    if (master < 0) return;

    NSString *banner = drain(master, 10);
    expect([banner containsString:@"vphoned session"], "the REPL announced itself: %s", banner.UTF8String);

    const char *script = "1 + 41\n";
    expect(write(master, script, strlen(script)) > 0, "the REPL took a line");
    NSString *answer = drain(master, 5);
    expect([answer containsString:@"42"], "and answered it: %s", answer.UTF8String);

    // A statement spread over two lines is held until it is complete.
    const char *split = "function twice(n) {\nreturn n * 2;\n}\ntwice(21)\n";
    write(master, split, strlen(split));
    answer = drain(master, 5);
    expect([answer containsString:@"42"], "a multi-line function was held and run: %s", answer.UTF8String);

    const char *help = ".help\n";
    write(master, help, strlen(help));
    answer = drain(master, 5);
    expect([answer containsString:@"ObjC.use"], ".help described the session: %s", answer.UTF8String);

    vp_session_resize(master, 120, 50);
    const char *columns = "ObjC.use('NSProcessInfo').processInfo().processName()\n";
    write(master, columns, strlen(columns));
    answer = drain(master, 5);
    expect([answer containsString:@"session-tests"], "the bridge works in a session: %s", answer.UTF8String);

    int status = vp_session_close(master, child, 3);
    expect(status != -1, "the session was reaped");
    expect(waitpid(child, NULL, WNOHANG) < 0, "and nothing is left of it");
}

static void executedProgram(void) {
    pid_t child = -1;
    int master = vp_session_open("/bin/sh", 80, 24, &child);
    expect(master >= 0, "a program opened on the terminal: %s", master >= 0 ? "yes" : strerror(errno));
    if (master < 0) return;

    const char *script = "echo from-the-shell\nexit\n";
    write(master, script, strlen(script));
    NSString *output = drain(master, 10);
    expect([output containsString:@"from-the-shell"], "the shell ran on the terminal: %s", output.UTF8String);
    vp_session_close(master, child, 3);
}

static void collectedProgram(void) {
    const char *argv[] = {"/bin/cat", NULL};
    int status = -1;
    char *output = NULL;
    char *errors = NULL;
    int failure = vp_spawn_collect("/bin/cat", argv, "piped in", &status, &output, &errors);
    expect(failure == 0, "cat ran: %s", strerror(failure));
    expect(output && strcmp(output, "piped in") == 0, "it echoed stdin: %s", output ?: "(none)");
    expect(errors && strcmp(errors, "") == 0, "with nothing on stderr");
    expect(WIFEXITED(status) && WEXITSTATUS(status) == 0, "and exited cleanly");
    free(output);
    free(errors);

    const char *missing[] = {"/no/such/program", NULL};
    failure = vp_spawn_collect("/no/such/program", missing, NULL, &status, &output, &errors);
    expect(failure == ENOENT, "a missing program is reported, not spawned: %s", strerror(failure));
    free(output);
    free(errors);
}

// MARK: - Entry

int main(void) {
    // vphoned's worker spawns its own executable to open a session. This test
    // stands in for it, so the spawning paths run against a real child.
    if (vp_native_process_mode() == 2) return vp_native_run_session();

    signal(SIGPIPE, SIG_IGN);
    runtimeBasics();
    outputCapture();
    bridgeBasics();
    bridgeRefusals();
    filesAndPrograms();
    guestAPI();
    sourceCompleteness();
    collectedProgram();
    oneShotEvaluation();
    descriptorAccounting();
    interactiveSession();
    executedProgram();
    printf("%d checks, %d failures\n", checks, failures);
    return failures == 0 ? 0 : 1;
}

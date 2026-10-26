#import "vphoned_session.h"

#import <Foundation/Foundation.h>

#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/wait.h>
#include <unistd.h>

// Checks the worker's side of a scripting session on the Mac: the one-shot
// and interactive session processes, their timeouts and terminals, and the
// one program a script's proc.run collects. No guest is needed, and because
// this test binary answers `--session` the way vphoned does, the spawning
// paths are exercised for real rather than stubbed. The script engine is
// IcliKit's probe, which builds only for iOS and tvOS and is tested in icli,
// so a stand-in session answers here in its place. `run-session-tests.sh`
// builds it.

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

// MARK: - The Stand-In Session

/// vphoned's GuestScriptSession, reduced to what the worker can observe.
/// `eval` answers its source back as one JSON line, except that `abort` dies
/// on a signal and `hang` never answers; `repl` echoes each line and reports
/// its terminal's size for `size`; `exec` is vphoned's own.
static int standInSession(void) {
    NSString *kind = NSProcessInfo.processInfo.arguments[2];
    if ([kind isEqualToString:@"exec"]) return vp_session_exec();
    vp_session_detach();
    if ([kind isEqualToString:@"eval"]) {
        NSData *input = [[NSFileHandle fileHandleWithStandardInput] readDataToEndOfFile];
        NSString *source = [[NSString alloc] initWithData:input encoding:NSUTF8StringEncoding] ?: @"";
        if ([source isEqualToString:@"abort"]) abort();
        if ([source isEqualToString:@"hang"]) {
            for (;;) pause();
        }
        NSData *reply = [NSJSONSerialization dataWithJSONObject:@{@"ok": @YES, @"result": source, @"output": @""}
                                                        options:0 error:nil];
        fwrite(reply.bytes, 1, reply.length, stdout);
        fputc('\n', stdout);
        return 0;
    }
    printf("stand-in session\n");
    fflush(stdout);
    char line[4096];
    while (fgets(line, sizeof(line), stdin)) {
        if (strncmp(line, "size", 4) == 0) {
            struct winsize size = {0};
            ioctl(STDIN_FILENO, TIOCGWINSZ, &size);
            printf("%dx%d\n", size.ws_col, size.ws_row);
        } else {
            printf("said: %s", line);
        }
        fflush(stdout);
    }
    return 0;
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
        char *reply = vp_session_evaluate("hang", 0.3, &status);
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
        expect([object[@"result"] isEqualToString:@"1 + 1"], "the source reached the session: %s", reply);
        expect(WIFEXITED(status) && WEXITSTATUS(status) == 0, "the session exited cleanly");
        free(reply);
    }

    // The reason a session is its own process: this one dies on a signal, and
    // the parent reports it rather than going down with it.
    reply = vp_session_evaluate("abort", 20, &status);
    expect(WIFSIGNALED(status) && WTERMSIG(status) == SIGABRT,
           "the session died on the signal, status %d", status);
    expect(!reply || !*reply, "and answered nothing");
    free(reply);

    // A session that never answers is killed, and the timeout is reported.
    double started = (double)time(NULL);
    reply = vp_session_evaluate("hang", 2, &status);
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
    expect([banner containsString:@"stand-in session"], "the session started: %s", banner.UTF8String);

    const char *line = "hello\n";
    expect(write(master, line, strlen(line)) > 0, "the session took a line");
    NSString *answer = drain(master, 5);
    expect([answer containsString:@"said: hello"], "and answered it: %s", answer.UTF8String);

    vp_session_resize(master, 120, 50);
    const char *size = "size\n";
    write(master, size, strlen(size));
    answer = drain(master, 5);
    expect([answer containsString:@"120x50"], "the terminal took its new size: %s", answer.UTF8String);

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

// MARK: - Running One Program

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

    const char *failing[] = {"/bin/sh", "-c", "echo oops >&2; exit 3", NULL};
    failure = vp_spawn_collect("/bin/sh", failing, NULL, &status, &output, &errors);
    expect(failure == 0, "sh ran: %s", strerror(failure));
    expect(errors && strcmp(errors, "oops\n") == 0, "its stderr was collected: %s", errors ?: "(none)");
    expect(WIFEXITED(status) && WEXITSTATUS(status) == 3, "with its exit status");
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
    if (vp_native_process_mode() == 2) return standInSession();

    signal(SIGPIPE, SIG_IGN);
    collectedProgram();
    oneShotEvaluation();
    descriptorAccounting();
    interactiveSession();
    executedProgram();
    printf("%d checks, %d failures\n", checks, failures);
    return failures == 0 ? 0 : 1;
}

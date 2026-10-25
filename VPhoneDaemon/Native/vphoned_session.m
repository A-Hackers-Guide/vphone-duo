#import "vphoned_session.h"

#import <Foundation/Foundation.h>

#include <crt_externs.h>
#include <dlfcn.h>
#include <errno.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <termios.h>
#include <unistd.h>

// The `--session` process: the worker spawned this to run one script or one
// interactive session, and nothing of the worker's own startup has run here.

static volatile sig_atomic_t vp_interrupted = 0;

static void vp_note_interrupt(int signal_number) {
    (void)signal_number;
    vp_interrupted = 1;
}

// MARK: - Arguments

/// `--session <kind> [program]`. Returns the kind, or NULL when the arguments
/// are not a session's.
static const char *vp_session_kind(int *argc, char ***argv) {
    int count = *_NSGetArgc();
    char **words = *_NSGetArgv();
    if (count < 3 || strcmp(words[1], "--session") != 0) return NULL;
    if (argc) *argc = count;
    if (argv) *argv = words;
    return words[2];
}

bool vp_session_arguments_present(void) {
    const char *kind = vp_session_kind(NULL, NULL);
    return kind && (strcmp(kind, "repl") == 0 || strcmp(kind, "eval") == 0 || strcmp(kind, "exec") == 0);
}

// MARK: - Controlling Terminal

/// Lead a process group of this session's own, and take the terminal as the
/// controlling one when there is a terminal.
///
/// The group comes first and applies to every kind of session: the worker
/// ends a session by signalling its group, and a program the script started
/// has to go with it rather than outlive it as an orphan. The terminal is
/// claimed by the child rather than by posix_spawn's file actions, so the
/// order never depends on the kernel's: ^C, job control and the hang-up that
/// ends an interactive session all need it in place before anything runs.
static void vp_session_detach(void) {
    setsid();
    if (!isatty(STDIN_FILENO)) return;
    ioctl(STDIN_FILENO, TIOCSCTTY, 0);
    tcsetpgrp(STDIN_FILENO, getpgrp());
}

// MARK: - Source Completeness

static bool vp_js_is_word(char character) {
    return character == '_' || character == '$' ||
           (character >= 'a' && character <= 'z') ||
           (character >= 'A' && character <= 'Z') ||
           (character >= '0' && character <= '9');
}

/// Whether a '/' here opens a regular expression rather than dividing. After
/// a value — a name, a number, a string, or a closing bracket — it divides;
/// after an operator, an opening bracket, or a keyword that takes an
/// expression, there is nothing for it to divide.
static bool vp_js_regex_starts(const char *source, const char *last) {
    if (!last) return true;
    char previous = *last;
    if (previous == ')' || previous == ']' || previous == '}' ||
        previous == '\'' || previous == '"' || previous == '`') {
        return false;
    }
    if (!vp_js_is_word(previous)) return true;
    const char *start = last;
    while (start > source && vp_js_is_word(start[-1])) start--;
    size_t length = (size_t)(last + 1 - start);
    static const char *const keywords[] = {
        "return", "typeof", "case", "in", "of", "new", "delete",
        "do", "else", "void", "instanceof", "yield", "await", "throw",
    };
    for (size_t index = 0; index < sizeof(keywords) / sizeof(*keywords); index++) {
        if (strlen(keywords[index]) == length && strncmp(start, keywords[index], length) == 0) {
            return true;
        }
    }
    return false;
}

/// The character after a regular expression's closing '/', or NULL when the
/// line ends first. A literal cannot span lines, so an unterminated one is a
/// syntax error for the engine to report rather than a statement the session
/// should wait for the rest of.
static const char *vp_js_after_regex(const char *slash) {
    bool in_class = false;
    for (const char *cursor = slash + 1; *cursor && *cursor != '\n'; cursor++) {
        if (*cursor == '\\') {
            if (!cursor[1] || cursor[1] == '\n') return NULL;
            cursor++;
            continue;
        }
        if (in_class) {
            if (*cursor == ']') in_class = false;
            continue;
        }
        if (*cursor == '[') in_class = true;
        else if (*cursor == '/') return cursor + 1;
    }
    return NULL;
}

bool vp_js_source_is_incomplete(const char *source) {
    if (!source) return false;
    int depth = 0;
    char quote = '\0';
    bool comment = false;
    // The last character that was not space. A '/' means one thing after a
    // value and another after an operator, and reading a regular expression
    // as a division is what makes `/['"]/` look like an unterminated string
    // and `/\{/` like an unclosed brace — either of which would leave the
    // session waiting for a line that is never coming.
    const char *last = NULL;
    for (const char *cursor = source; *cursor; cursor++) {
        char character = *cursor;
        if (comment) {
            if (character == '*' && cursor[1] == '/') {
                comment = false;
                cursor++;
                last = cursor;
            }
            continue;
        }
        if (quote) {
            if (character == '\\' && cursor[1]) {
                cursor++;
            } else if (character == quote) {
                quote = '\0';
                last = cursor;
            }
            continue;
        }
        switch (character) {
        case '\'': case '"': case '`': quote = character; break;
        case '/':
            if (cursor[1] == '*') {
                comment = true;
                cursor++;
                continue;
            }
            if (cursor[1] == '/') {
                while (cursor[1] && cursor[1] != '\n') cursor++;
                continue;
            }
            if (vp_js_regex_starts(source, last)) {
                const char *after = vp_js_after_regex(cursor);
                if (after) {
                    cursor = after - 1;
                    last = cursor;
                    continue;
                }
            }
            break;
        case '(': case '[': case '{': depth++; break;
        case ')': case ']': case '}': if (depth > 0) depth--; break;
        default: break;
        }
        if (character != ' ' && character != '\t' && character != '\n' && character != '\r') {
            last = cursor;
        }
    }
    // A single-quoted or double-quoted string cannot span lines in JavaScript,
    // so only a template literal keeps the statement open.
    return depth > 0 || comment || quote == '`';
}

// MARK: - Reading Lines

static char *(*vp_readline)(const char *);
static void (*vp_add_history)(const char *);

/// libedit gives the session history and line editing. It is not a given on
/// every guest, and the terminal's own canonical mode still handles
/// backspace, ^U and ^C without it.
static void vp_load_line_editor(void) {
    void *library = dlopen("/usr/lib/libedit.3.dylib", RTLD_LAZY | RTLD_LOCAL);
    if (!library) library = dlopen("libedit.dylib", RTLD_LAZY | RTLD_LOCAL);
    if (!library) return;
    vp_readline = dlsym(library, "readline");
    vp_add_history = dlsym(library, "add_history");
    if (!vp_readline) vp_add_history = NULL;
}

/// One line without its newline, malloc-owned, or NULL at end of input.
/// `*interrupted` is set when ^C arrived instead of a line.
static char *vp_read_line(const char *prompt, bool *interrupted) {
    *interrupted = false;
    vp_interrupted = 0;
    if (vp_readline) {
        char *line = vp_readline(prompt);
        if (!line && vp_interrupted) {
            *interrupted = true;
            return NULL;
        }
        if (line && *line && vp_add_history) vp_add_history(line);
        return line;
    }

    fputs(prompt, stdout);
    fflush(stdout);
    char bytes[4096];
    if (!fgets(bytes, sizeof(bytes), stdin)) {
        if (vp_interrupted) {
            *interrupted = true;
            clearerr(stdin);
        }
        return NULL;
    }
    size_t length = strlen(bytes);
    while (length > 0 && (bytes[length - 1] == '\n' || bytes[length - 1] == '\r')) {
        bytes[--length] = '\0';
    }
    return strdup(bytes);
}

// MARK: - The REPL

static const char *vp_session_help =
    "vphoned session. Everything here runs as vphoned, in this process.\n"
    "\n"
    "  ObjC.use('NSProcessInfo')      a class; call its methods by name\n"
    "  ObjC.classes.NSFileManager     the same, by property\n"
    "  obj.setValue_forKey_(v, k)     an underscore stands for a colon\n"
    "  obj['setValue:forKey:'](v, k)  or write the selector out\n"
    "  obj.$value   obj.$class        a collection as plain JSON; its class\n"
    "  api('device.snapshot', {})     any guest API method, in process\n"
    "  fs.ls / read / write / stat    files, as root\n"
    "  proc.run(path, [args])         one program, with its output\n"
    "  console.log, print, sleep(ms)  output and waiting\n"
    "  .exit  .help                   leave, or print this again\n"
    "  ^C                             abandon a half-finished statement\n";

static int vp_session_repl(void) {
    vp_session_detach();
    struct sigaction interrupt = {.sa_handler = vp_note_interrupt};
    sigemptyset(&interrupt.sa_mask);
    sigaction(SIGINT, &interrupt, NULL);

    if (!vp_js_start()) {
        fputs("This guest has no JavaScriptCore, so there is no session to open.\n", stderr);
        return 70;
    }
    vp_load_line_editor();
    NSOperatingSystemVersion version = NSProcessInfo.processInfo.operatingSystemVersion;
    printf("vphoned session on %ld.%ld.%ld, pid %d. .help for what is here.\n",
           (long)version.majorVersion, (long)version.minorVersion, (long)version.patchVersion, getpid());
    fflush(stdout);

    NSMutableString *pending = [NSMutableString string];
    for (;;) {
        bool interrupted = false;
        char *line = vp_read_line(pending.length ? "   ... " : "vphoned> ", &interrupted);
        if (interrupted) {
            [pending setString:@""];
            fputs("\n", stdout);
            continue;
        }
        if (!line) break;
        NSString *text = @(line);
        free(line);

        if (!pending.length) {
            NSString *command = [text stringByTrimmingCharactersInSet:
                                          [NSCharacterSet whitespaceAndNewlineCharacterSet]];
            if ([command isEqualToString:@".exit"] || [command isEqualToString:@".quit"]) break;
            if ([command isEqualToString:@".help"]) {
                fputs(vp_session_help, stdout);
                fflush(stdout);
                continue;
            }
            if (!command.length) continue;
        }
        [pending appendString:text ?: @""];
        [pending appendString:@"\n"];
        if (vp_js_source_is_incomplete(pending.UTF8String)) continue;

        char *failure = NULL;
        char *described = vp_js_evaluate(pending.UTF8String, &failure);
        [pending setString:@""];
        if (described) {
            if (strcmp(described, "undefined") != 0) printf("%s\n", described);
            free(described);
        } else {
            fprintf(stderr, "%s\n", failure ?: "Unknown error");
            free(failure);
        }
        fflush(stdout);
        fflush(stderr);
    }
    return 0;
}

// MARK: - One-Shot Evaluation

/// Everything on stdin, which the worker closes once it has sent the source.
static NSString *vp_read_all_input(void) {
    NSMutableData *collected = [NSMutableData data];
    char bytes[16384];
    for (;;) {
        ssize_t count = read(STDIN_FILENO, bytes, sizeof(bytes));
        if (count > 0) {
            if (collected.length < (4u << 20)) [collected appendBytes:bytes length:(NSUInteger)count];
            continue;
        }
        if (count < 0 && errno == EINTR) continue;
        break;
    }
    return [[NSString alloc] initWithData:collected encoding:NSUTF8StringEncoding] ?: @"";
}

static void vp_write_reply(NSDictionary *reply) {
    NSData *encoded = [NSJSONSerialization dataWithJSONObject:reply options:0 error:nil];
    if (!encoded) {
        encoded = [@"{\"ok\":false,\"error\":\"The reply could not be encoded\"}" dataUsingEncoding:NSUTF8StringEncoding];
    }
    fwrite(encoded.bytes, 1, encoded.length, stdout);
    fputc('\n', stdout);
    fflush(stdout);
}

static int vp_session_eval(void) {
    // No terminal here, but the group still matters: a timed-out session is
    // killed by its group so that nothing the script started is left behind.
    vp_session_detach();
    NSString *source = vp_read_all_input();
    vp_js_capture_output(true);
    if (!vp_js_start()) {
        vp_write_reply(@{@"ok": @NO, @"error": @"This guest has no JavaScriptCore", @"output": @""});
        return 70;
    }
    char *failure = NULL;
    char *described = vp_js_evaluate(source.UTF8String ?: "", &failure);
    char *output = vp_js_take_output();
    bool evaluated = described != NULL;
    NSMutableDictionary *reply = [NSMutableDictionary dictionary];
    reply[@"output"] = @(output ?: "");
    if (evaluated) {
        reply[@"ok"] = @YES;
        reply[@"result"] = @(described);
    } else {
        reply[@"ok"] = @NO;
        reply[@"error"] = @(failure ?: "Unknown error");
    }
    free(described);
    free(failure);
    free(output);
    vp_write_reply(reply);
    return evaluated ? 0 : 65;
}

// MARK: - Entry

static int vp_session_exec(int argc, char **argv) {
    if (argc < 4) {
        fputs("vphoned --session exec needs a program\n", stderr);
        return 64;
    }
    vp_session_detach();
    execv(argv[3], &argv[3]);
    fprintf(stderr, "vphoned session: %s: %s\n", argv[3], strerror(errno));
    return 127;
}

int vp_native_run_session(void) {
    int argc = 0;
    char **argv = NULL;
    const char *kind = vp_session_kind(&argc, &argv);
    if (!kind) return 64;
    if (strcmp(kind, "repl") == 0) return vp_session_repl();
    if (strcmp(kind, "eval") == 0) return vp_session_eval();
    if (strcmp(kind, "exec") == 0) return vp_session_exec(argc, argv);
    fprintf(stderr, "vphoned session: unknown kind %s\n", kind);
    return 64;
}

#import "vphoned_session.h"

#include <crt_externs.h>
#include <errno.h>
#include <stdio.h>
#include <string.h>
#include <sys/ioctl.h>
#include <unistd.h>

// The `--session` process: the worker spawned this to run one script or one
// interactive session, and nothing of the worker's own startup has run here.
// A script runs in IcliKit's probe, driven from GuestScriptSession.swift; this
// file keeps what the process has to settle natively before it does.

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

/// The group comes first and applies to every kind of session: the worker
/// ends a session by signalling its group, and a program the script started
/// has to go with it rather than outlive it as an orphan. The terminal is
/// claimed by the child rather than by posix_spawn's file actions, so the
/// order never depends on the kernel's: ^C, job control and the hang-up that
/// ends an interactive session all need it in place before anything runs.
void vp_session_detach(void) {
    setsid();
    if (!isatty(STDIN_FILENO)) return;
    ioctl(STDIN_FILENO, TIOCSCTTY, 0);
    tcsetpgrp(STDIN_FILENO, getpgrp());
}

// MARK: - Running a Program

int vp_session_exec(void) {
    int argc = 0;
    char **argv = NULL;
    const char *kind = vp_session_kind(&argc, &argv);
    if (!kind || strcmp(kind, "exec") != 0 || argc < 4) {
        fputs("vphoned --session exec needs a program\n", stderr);
        return 64;
    }
    vp_session_detach();
    vp_execv(argv[3], &argv[3]);
    fprintf(stderr, "vphoned session: %s: %s\n", argv[3], strerror(errno));
    return 127;
}

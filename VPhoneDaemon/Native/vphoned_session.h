#pragma once
#include "Include/VphonedNative.h"

#include <stdbool.h>
#include <sys/types.h>

// The scripting session, which runs in its own process. vphoned has no shell
// and the tvos preset has no debugger, so a session is the only way to run
// code with vphoned's identity inside a guest. Everything here belongs to the
// `--session` process; the worker side is declared in VphonedNative.h.

/// Whether this process's arguments name a session, which decides the
/// process mode before anything else has run.
bool vp_session_arguments_present(void);

// MARK: - JavaScript Runtime

/// Build the session's context and install its globals. False when
/// JavaScriptCore is missing or the prelude failed to evaluate.
bool vp_js_start(void);

/// Collect what the script writes instead of letting it reach stdout, which
/// `eval` needs: its own stdout carries one JSON line and nothing else.
void vp_js_capture_output(bool enabled);

/// The collected output so far, malloc-owned, clearing the buffer.
char *vp_js_take_output(void);

/// Evaluate `source` and describe its value. Returns malloc-owned text, or
/// NULL with `*error` set to a malloc-owned message.
char *vp_js_evaluate(const char *source, char **error);

/// Whether `source` ends inside an open brace, bracket, string or comment,
/// which the REPL continues on the next line instead of evaluating.
bool vp_js_source_is_incomplete(const char *source);

// MARK: - Session Processes

/// Run one program and collect what it writes. `input` may be NULL. Both
/// outputs are malloc-owned and always set on success. Returns 0, or an errno
/// value; `*status` is the wait status.
int vp_spawn_collect(const char *path, const char *const *argv, const char *input,
                     int *status, char **output, char **errors);

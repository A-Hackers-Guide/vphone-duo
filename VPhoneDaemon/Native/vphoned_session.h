#pragma once
#include "Include/VphonedNative.h"

#include <stdbool.h>

// The scripting session, which runs in its own process. vphoned has no shell
// and the tvos preset has no debugger, so a session is the only way to run
// code with vphoned's identity inside a guest. The script itself runs in
// IcliKit's probe (GuestScriptSession.swift); what the `--session` process
// settles natively, and the worker side, are declared in VphonedNative.h.

/// Whether this process's arguments name a session, which decides the
/// process mode before anything else has run.
bool vp_session_arguments_present(void);

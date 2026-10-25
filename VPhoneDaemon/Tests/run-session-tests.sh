#!/bin/zsh
set -euo pipefail

# Builds the scripting session's native sources with SessionTests.m for the
# Mac and runs them: the JavaScript runtime, the ObjC bridge, the session
# process modes, and the pseudo-terminal the worker opens for an interactive
# session. The test binary answers `--session` the way vphoned does, so the
# spawning paths run against a real child. No guest is needed.
#
# JavaScriptCore is linked weakly here for the same reason vphoned links it
# weakly: watchOS has no copy, and the daemon has to start anyway.

daemon="${0:a:h:h}"
temporary="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/vphone-session-tests.XXXXXX")"
trap '/bin/rm -rf "$temporary"' EXIT

/usr/bin/xcrun --sdk macosx clang -std=gnu11 -fobjc-arc -Wall -Wextra -Werror \
    -I "$daemon/Native" -I "$daemon/Native/Include" \
    -framework Foundation -weak_framework JavaScriptCore \
    "$daemon/Native/vphoned_proxy.c" \
    "$daemon/Native/vphoned_pty.c" \
    "$daemon/Native/vphoned_session.m" \
    "$daemon/Native/vphoned_jsbridge.m" \
    "$daemon/Native/vphoned_jscontext.m" \
    "$daemon/Tests/SessionTests.m" \
    -o "$temporary/session-tests"

"$temporary/session-tests"

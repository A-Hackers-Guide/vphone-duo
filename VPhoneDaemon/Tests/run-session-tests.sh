#!/bin/zsh
set -euo pipefail

# Builds the scripting session's native sources with SessionTests.m for the
# Mac and runs them: the session process modes, their timeouts, the
# pseudo-terminal the worker opens for an interactive session, and the one
# program a script's proc.run collects. The test binary answers `--session`
# the way vphoned does, so the spawning paths run against a real child. No
# guest is needed. The script engine is IcliKit's probe, tested in icli.

daemon="${0:a:h:h}"
temporary="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/vphone-session-tests.XXXXXX")"
trap '/bin/rm -rf "$temporary"' EXIT

/usr/bin/xcrun --sdk macosx clang -std=gnu11 -fobjc-arc -Wall -Wextra -Werror \
    -I "$daemon/Native" -I "$daemon/Native/Include" \
    -framework Foundation \
    "$daemon/Native/vphoned_proxy.c" \
    "$daemon/Native/vphoned_pty.c" \
    "$daemon/Native/vphoned_session.m" \
    "$daemon/Tests/SessionTests.m" \
    -o "$temporary/session-tests"

"$temporary/session-tests"

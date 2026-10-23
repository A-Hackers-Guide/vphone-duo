#!/bin/zsh
set -euo pipefail
SCRIPT_DIR="${0:a:h}"
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/vphone-homepod-debug-tests.XXXXXX")"
trap 'rm -rf "$TEST_DIR"' EXIT
xcrun --sdk macosx clang -fobjc-arc -fmodules -Wall -Wextra -Werror \
    -fmodules-cache-path="$TEST_DIR/modules" -framework Foundation \
    "$SCRIPT_DIR/HomePodDebugTests.m" -o "$TEST_DIR/homepod-debug-tests"
"$TEST_DIR/homepod-debug-tests"

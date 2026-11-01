#!/bin/zsh
set -euo pipefail
test_root="${0:a:h}"
test_work="$(mktemp -d "${TMPDIR:-/tmp}/vphone-foldguard-tests.XXXXXX")"
trap 'rm -rf "$test_work"' EXIT
xcrun --sdk macosx clang -fobjc-arc -fblocks -framework Foundation \
    "$test_root/FoldGuardTests.m" -o "$test_work/FoldGuardTests"
"$test_work/FoldGuardTests"

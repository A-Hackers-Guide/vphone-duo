#!/bin/zsh
set -euo pipefail

tests="${0:a:h}"
temporary="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/vphone-homepod-display-tests.XXXXXX")"
trap '/bin/rm -rf "$temporary"' EXIT

/usr/bin/xcrun --sdk macosx clang -std=c11 -Wall -Wextra -Werror \
    "$tests/HomePodDisplayReportTests.c" -o "$temporary/report-tests"
"$temporary/report-tests"

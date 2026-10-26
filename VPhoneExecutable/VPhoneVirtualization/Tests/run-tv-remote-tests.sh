#!/bin/zsh
set -euo pipefail

tests="${0:a:h}"
remote="$tests:h/UI/UserInterface/Panels/TVRemote"
temporary="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/vphone-tv-remote.XXXXXX")"
trap '/bin/rm -rf "$temporary"' EXIT

/usr/bin/xcrun --sdk macosx swiftc -swift-version 6 -strict-concurrency=complete \
    -module-cache-path "$temporary/ModuleCache" \
    "$remote/VPhoneTVRemoteInput.swift" "$remote/VPhoneTVRemoteView.swift" \
    "$tests/TVRemoteTests.swift" -o "$temporary/TVRemoteTests"
"$temporary/TVRemoteTests" "$@"

#!/bin/zsh
set -euo pipefail

launchpad="${0:a:h:h}"
temporary="$(/usr/bin/mktemp -d)"
trap '/bin/rm -rf "$temporary"' EXIT

/usr/bin/xcrun swiftc -swift-version 6 -strict-concurrency=complete \
    -parse-as-library \
    "$launchpad/VPhoneLaunchpad/Machines/VPhoneLaunchpadMaintenanceProgress.swift" \
    "$launchpad/Tests/MaintenanceProgressTests.swift" \
    -o "$temporary/maintenance-progress-tests"
"$temporary/maintenance-progress-tests" "$@"

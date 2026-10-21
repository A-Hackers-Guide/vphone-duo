#!/bin/zsh
set -euo pipefail
tests=${0:a:h}
tmp=$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/ota-driver-tests.XXXXXX")
trap '/bin/rm -rf "$tmp"' EXIT
export PATH="$tests/fixtures:/usr/bin:/bin:/usr/sbin:/sbin"
export OTA_TEST_LOG="$tmp/calls"
driver="$tests/../ota-upgrade.zsh"

/bin/zsh "$driver" test test-bundle phone.ipsw cloud.ipsw full.aea key com.example.app > /dev/null 2>&1
if /usr/bin/grep -q 'fw ota rollback' "$OTA_TEST_LOG"; then exit 1; fi
/usr/bin/grep -q 'cfw install test' "$OTA_TEST_LOG"
/usr/bin/grep -q 'fw ota complete test' "$OTA_TEST_LOG"
/usr/bin/grep -q 'fw ota isolate test' "$OTA_TEST_LOG"
/usr/bin/grep -q 'fw ota commit test' "$OTA_TEST_LOG"
/usr/bin/grep -q 'fw ota verify test' "$OTA_TEST_LOG"

export OTA_TEST_LOG="$tmp/prepare-failure"
export OTA_TEST_FAIL_PHASE=prepare
if /bin/zsh "$driver" test test-bundle phone.ipsw cloud.ipsw full.aea > /dev/null 2>&1; then exit 1; fi
/usr/bin/grep -q 'fw ota rollback test' "$OTA_TEST_LOG"
if /usr/bin/grep -q 'cfw install test' "$OTA_TEST_LOG"; then exit 1; fi

export OTA_TEST_LOG="$tmp/checkpoint-failure"
export OTA_TEST_FAIL_PHASE=checkpoint
if /bin/zsh "$driver" test test-bundle phone.ipsw cloud.ipsw full.aea > /dev/null 2>&1; then exit 1; fi
if /usr/bin/grep -q 'fw ota rollback test' "$OTA_TEST_LOG"; then exit 1; fi
/usr/bin/grep -q 'vm start test' "$OTA_TEST_LOG"

export OTA_TEST_LOG="$tmp/wrong-binding"
unset OTA_TEST_FAIL_PHASE
if /bin/zsh "$driver" test wrong-bundle phone.ipsw cloud.ipsw full.aea > /dev/null 2>&1; then exit 1; fi
if /usr/bin/grep -q 'vm stop' "$OTA_TEST_LOG"; then exit 1; fi

export OTA_TEST_LOG="$tmp/post-commit-failure"
export OTA_TEST_FAIL_PHASE=verify
if /bin/zsh "$driver" test test-bundle phone.ipsw cloud.ipsw full.aea > /dev/null 2>&1; then exit 1; fi
if /usr/bin/grep -q 'fw ota rollback test' "$OTA_TEST_LOG"; then exit 1; fi
if [[ $(/usr/bin/tail -1 "$OTA_TEST_LOG") != 'vm stop test' ]]; then exit 1; fi
print 'OTA driver: success, rollback, checkpoint failure and wrong-binding checks passed'

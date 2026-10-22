#!/bin/zsh
set -euo pipefail

# Developer coordinator for the durable fw ota phases. Every VM and privileged
# action uses Launchpad, including its fixed cfw install helper verb.
if (( $# < 5 )); then
  print -u2 'usage: ota-upgrade.zsh VM BUNDLE TARGET-IPSW CLOUDOS-IPSW FULL-OTA [AEA-KEY] [APP-ID ...]'
  exit 2
fi
vm=$1
bundle_version=$2
iphone_source=$3
cloudos_source=$4
ota_source=$5
ota_key=${6:-}
protected_apps=("${@:7}")
cli=$(command -v vphone-launchpad-cli)
completed=false
checkpointed=false
stop_requested=false
commit_requested=false

# Keep `phase X || exit $?`: an errexit exit from inside this function does
# not run the EXIT trap in zsh, so recover would never roll back.
phase() { "$cli" exec --bundle "$bundle_version" fw ota "$1" "$vm" "${@:2}"; }
recover() {
  local code=$?
  trap - EXIT INT TERM
  if [[ $completed == true ]]; then
    exit "$code"
  elif [[ $commit_requested == true ]]; then
    "$cli" vm stop "$vm" || true
    print -u2 'OTA reached its network commit boundary. Target data is retained; resume commit/verify without automatically discarding writes made after networking resumed.'
  elif [[ $checkpointed == true ]]; then
    print -u2 'OTA did not complete; restoring its stopped checkpoint.'
    if "$cli" vm stop "$vm" && phase rollback --force; then
      "$cli" vm start "$vm" --headless --wait --timeout 600 || true
    else
      print -u2 'Rollback could not finish. The OTA journal and snapshot are retained; keep the VM stopped and resume recovery.'
    fi
  elif [[ $stop_requested == true ]]; then
    # Checkpointing has not changed the guest. Put the running source back
    # even when a host backup or snapshot failed before it could be recorded.
    "$cli" vm start "$vm" --headless --wait --timeout 600 || true
  fi
  exit "$code"
}
trap recover EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# Capability and journal checks happen before the source is stopped. The VM
# must already be bound to this installed bundle; cfw install uses that binding.
machines=$("$cli" vm list)
matches=0
for (( index=0; index<10000; index++ )); do
  if ! candidate=$(print -rn -- "$machines" | /usr/bin/plutil -extract "$index.name" raw -o - - 2>/dev/null); then break; fi
  if [[ $candidate != "$vm" ]]; then continue; fi
  (( matches += 1 ))
  bound=$(print -rn -- "$machines" | /usr/bin/plutil -extract "$index.bundle" raw -o - -)
  if [[ $bound != "$bundle_version" ]]; then
    print -u2 "VM $vm is bound to $bound, not requested OTA bundle $bundle_version. Bind it explicitly before upgrading."
    exit 2
  fi
done
if (( matches != 1 )); then
  print -u2 "Expected exactly one VM named $vm in Launchpad; found $matches."
  exit 2
fi
"$cli" exec --bundle "$bundle_version" fw ota --help >/dev/null
capture_args=()
for app in "${protected_apps[@]}"; do capture_args+=(--app "$app"); done
phase capture "${capture_args[@]}" || exit $?
stop_requested=true
"$cli" vm stop "$vm"
phase checkpoint || exit $?
checkpointed=true
phase isolate || exit $?
"$cli" vm start "$vm" --headless --wait --timeout 600
phase quiesce || exit $?
"$cli" vm stop "$vm"
prepare_args=(--iphone-source "$iphone_source" --cloudos-source "$cloudos_source" --source "$ota_source")
if [[ -n $ota_key ]]; then prepare_args+=(--key "$ota_key"); fi
phase prepare "${prepare_args[@]}" || exit $?
"$cli" cfw install "$vm"
"$cli" vm start "$vm" --headless --wait --timeout 600

# vphoned readiness precedes DataMigrator, UI and profiled readiness. A bounded
# retry is allowed to dismiss post-update Setup and await effective Auto-Lock.
for attempt in {1..60}; do
  if phase complete; then
    # Service profile overrides settle at boot. Verify a cold start before
    # returning the upgraded machine to its normal workload.
    "$cli" vm stop "$vm"
    "$cli" vm start "$vm" --headless --wait --timeout 600
    phase complete || exit $?
    "$cli" vm stop "$vm"
    commit_requested=true
    phase commit || exit $?
    "$cli" vm start "$vm" --headless --wait --timeout 600
    phase verify || exit $?
    completed=true
    print -u2 'OTA completed. Its pre-upgrade snapshot and host recovery state are retained.'
    exit 0
  fi
  /bin/sleep 10
done
print -u2 'Target migration or policy verification did not finish within 10 minutes.'
exit 1

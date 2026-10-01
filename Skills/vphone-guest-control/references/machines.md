# Machines: create, run, update

## Contents

- Inspect
- Create
- Retry a failed creation
- Start, wait, stop
- Logs
- Updating a machine's guest components
- Where things live

## Inspect

```sh
vphone-launchpad-cli vm list
```

One object per machine: `name`, `libraryRoot`, `state` (`stopped`, `running`,
`busy: <activity>`), `cpuCount`, `memoryMB`, `network`, `panicked`, `log`,
`controlSocket` (null until the machine serves `vphone.sock`), and when known
`udid`, `ios` and `cloudOS`. Check `state` before any machine command; start
and update refuse a machine that is not `stopped`.

## Create

A creation downloads two IPSWs, patches the boot chain, restores through DFU,
installs the custom firmware into the guest, and boots once to prove vphoned
answers. It leaves a **stopped** machine. Success is not a running guest.

Before starting, check free disk (tens of GB, more with `--keep-artifacts`),
that no other creation is running, and that `status` shows `bundleReady`.

```sh
vphone-launchpad-cli vm create myphone \
  [--iphone-source <path-or-url>] [--cloudos-source <path-or-url>] \
  [--cpu 8] [--memory 8192] [--disk-size 64] \
  [--network nat|bridged|none] [--preset standard|experimental] \
  [--keep-artifacts] [--no-wait]
```

- **Sources are optional.** If either is omitted, the newest pairing from
  `vphone-cli fw catalog` is used (the CLI prints `firmware: <iphone> + <cloudos>`).
  Pass both explicitly to pin a pairing; verified pairings are listed in
  `Documents/Guides/compatibility.md`. Local paths are read in place; URLs are
  cached in `~/.vphone/ipsws/`.
- **Units:** `--cpu` is a count, `--memory` is **MB**, `--disk-size` is **GB**.
  Defaults 8, 8192, 64. All must be positive integers.
- **Name:** letters, digits, `.`, `-`, `_`. Keep it short: the machine path must
  fit a Unix socket path, and the command says so if it does not.
- **`--preset`** picks the patch preset: `standard` (default) or `experimental`.
- **`--no-wait`** returns at once with a report instead of streaming the
  pipeline. Without it the CLI streams the creation log and returns when the
  pipeline stops.
- The nine steps, in order: `create`, `prepare`, `patch`, `bootDFU`, `waitDFU`,
  `restore`, `stopDFU`, `installCFW`, `firstBoot`. The final JSON report lists
  each with `status` and `seconds`, plus the `log` path.
- Creation needs network access for the restore ticket. Do not interrupt a
  restore by killing processes; the window owns it.

If the name exists or a creation under it is running, the command refuses.
Choose a new name rather than reusing a half-built machine.

## Retry a failed creation

```sh
vphone-launchpad-cli vm create myphone --from restore
```

`--from` takes one of the step names above and reruns from there. It works only
for a creation **this running Launchpad has started since it launched**; after a
relaunch it says there is nothing to retry. In that case create under a new
name. Read why it failed first:

```sh
vphone-launchpad-cli vm log myphone --kind create --lines 200   # create | dfu | patch
```

## Start, wait, stop

```sh
vphone-launchpad-cli vm start myphone --wait [--timeout 300]
vphone-launchpad-cli vm start myphone --headless --wait
vphone-launchpad-cli vm wait myphone --timeout 300
vphone-launchpad-cli vm stop myphone
```

- `--wait` pings vphoned over `vphone.sock` every second until it answers. It
  fails early, with the console log path, on a kernel panic or when the VM
  process exits. The default timeout is 300 s, which first boots can use up.
- A window opens by default. `--headless` runs without one, and the guest is
  driven entirely through `vphone.sock`.
- `vm start` refuses a machine that is running or busy. If the VM was started
  elsewhere, use `vm wait`.

## Logs

```sh
vphone-launchpad-cli vm log myphone --lines 100
vphone-launchpad-cli vm log myphone --kind create|dfu|patch --lines 200
```

Files live in `~/Library/Logs/vphone-launchpad/`: `<name>.log` (VM console and
kernel output), `<name>-create.log`, `<name>-dfu.log`, `<name>-patch.log`.

## Updating a machine's guest components

For a **stopped** machine:

```sh
vphone-launchpad-cli cfw update-environment myphone
```

This redeploys the active bundle's guest resources (vphoned and the hook
dylibs) and changes nothing else. Do it after moving to another bundle version.
`cfw install myphone` redoes the whole custom-firmware install through the root
helper; use it only to repair a machine, and only when asked.

## Where things live

| Path | Contents |
| --- | --- |
| `~/.vphone/machines/<name>/` | One machine: disk, `config.plist`, `vphone.sock` while running |
| `~/.vphone/ipsws/` | Downloaded source IPSWs, shared |
| `~/.vphone/gpu-drivers/<version>_<build>/` | GPU driver extracted per cloudOS build, shared |
| `~/Library/Logs/vphone-launchpad/` | Console and creation logs |

`VPHONE_ROOT` relocates the library and caches. Launchpad can hold several
libraries; `status.libraries` lists them.

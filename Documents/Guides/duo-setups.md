# Duo setups: developer, jailbreak and custom

A new vphone guest is left empty on purpose: no package manager, no SSH, no
VNC ([Create and run](create-and-run.md)). `scripts/duo/vphone-duo setup`
does, when you ask, what you would otherwise do by hand on a Duo guest. It
uses only vphoned's documented methods
([guest control](../../Skills/vphone-guest-control/SKILL.md)); it changes
nothing about what iOS believes it runs on.

```sh
scripts/duo/vphone-duo setup status
scripts/duo/vphone-duo setup dev
scripts/duo/vphone-duo setup jb --manager sileo --ssh-key ~/.ssh/id_ed25519.pub
scripts/duo/vphone-duo setup custom my-duo.json
```

Add `--vm NAME` for a machine other than `duo`.

## dev

- Developer Mode on (`developer_mode.enable`; iOS may ask to restart to finish).
- Setup Assistant skipped if it is still showing.
- Auto-Lock Never, so the screen stays on while you work. iOS applies it within
  a few seconds.

## jb

`dev`, then:

1. **The bootstrap.** `bootstrap.install` puts Irisin and the base directories
   in place, roothide by default (`--layout rootless` for the older layout).
   Takes a few seconds; the guest needs network.
2. **One step in Irisin.** The first package install has no API
   ([guest layout](../../Skills/vphone-guest-control/references/guest-layout.md)).
   Open Irisin and:
   - On its welcome screens, add the repositories it recommends. For roothide
     on iOS 16 and later these are Irisin's own defaults
     (`default-list-iphoneos-arm64e.plist` inside the app):
     - `https://roothide.github.io`
     - `deb https://roothide.github.io/procursus iphoneos-arm64e/1900 main`:
       roothide's Procursus, where dpkg, bash, apt and openssh come from
     - `https://apt.owngoal.dev`
   - Search for **OwnGoal Bootstrap for vphone**, add it to the queue.
   - Long-press **Execute** and choose **Bootstrap Install**.

   The profile waits for apt to appear (`--wait`, 20 minutes by default;
   `--wait 0` prints the steps and stops, and running it again picks up
   where it left off).
3. **A package manager** through the bootstrap's apt:
   - `--manager sileo` (default) or `--manager zebra`. Both have roothide and
     rootless builds.
   - `--manager cydia` is refused with the reason: Cydia only runs on rootful
     jailbreaks, and vphone guests are roothide or rootless. Sileo and Zebra
     read the same repositories.
   - `--manager none` skips it.
4. **SSH.** The bootstrap brings `openssh-server`. `--ssh-key` adds your
   public key to `mobile`'s `authorized_keys` (no password is set or needed).
   Connect through usbmuxd:

   ```sh
   iproxy 2222 22 -u "$(idevice_id -l | head -1)" &
   ssh -p 2222 mobile@127.0.0.1
   ```

   `iproxy` and `idevice_id` are libimobiledevice's (`brew install libimobiledevice`).

## custom

A JSON file with any of these keys:

```json
{
  "developer": true,
  "appearance": "dark",
  "auto_lock": "never",
  "bootstrap": "roothide",
  "wait_minutes": 20,
  "manager": "zebra",
  "packages": ["htop", "nano"],
  "ssh_key": "~/.ssh/id_ed25519.pub"
}
```

Unknown keys are refused, so a typo does not pass silently. Steps run in the
order of the `jb` profile; anything without `bootstrap` stops after the
settings.

## Appearance

`vphone-duo appearance dark|light` sets iOS's appearance, as Settings ▸
Display & Brightness does (`UserInterfaceStyleMode` in
`com.apple.uikitservices.userInterfaceStyleMode`, for `mobile`). The Duo
window does the same with its finish: **Space Black** turns iOS dark, **Star
White** light, from the bar, the Fold menu or the socket, and again whenever
the guest reconnects. `VPHONE_DUO_FOLLOW_FINISH=0` leaves iOS's appearance
alone.

## What was tested

On a copy-on-write clone of the 27.2 Duo guest, 2026-10-28:

| Step | Result |
| --- | --- |
| `appearance dark` / `light`, and the window's finish | iOS switches live, both ways |
| `setup dev` | Developer Mode on, Auto-Lock Never requested |
| `setup jb`, the bootstrap | Irisin 5.0.3 (roothide) installed in seconds; uninstall and reinstall clean |
| `setup jb`, the Irisin step | instructions verified against Irisin 5.0.3; OwnGoal's meta package needs the Procursus repository for its base packages |
| `setup jb`, package manager and SSH key | written against apt's and vphoned's documented behaviour; **not yet run end to end** (it needs the in-app step) |
| `setup status` | reports layout, root, apt and sshd |

Removing everything: `vphone-duo rpc bootstrap.inspect`, then
`bootstrap.uninstall` with the listed roots (it reboots the guest).

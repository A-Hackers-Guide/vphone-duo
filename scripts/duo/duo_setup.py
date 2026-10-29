"""Setup profiles for an iPhone Duo guest: developer, jailbreak and custom.

A fresh vphone guest is left empty on purpose (Documents/Guides/create-and-run.md).
These profiles do, on request, what an owner otherwise does by hand, using
only vphoned's documented methods (Skills/vphone-guest-control):

  dev     Developer Mode on, Setup Assistant skipped, Auto-Lock Never.
  jb      dev, then the Irisin bootstrap (roothide unless asked otherwise),
          then, once Irisin's one in-app step is done, a package manager and
          your SSH key through the bootstrap's apt.
  custom  any of the above from a JSON file; see Documents/Guides/duo-setups.md.

Nothing here hides the VM from iOS or changes what iOS believes it runs on.
"""
import json
import os
import time

# What the Duo window's finish asks of iOS: 1 Light, 2 Dark.
APPEARANCE_DOMAIN = "com.apple.uikitservices.userInterfaceStyleMode"
APPEARANCE_KEY = "UserInterfaceStyleMode"
APPEARANCES = {"light": 1, "dark": 2}

# Auto-Lock Never, as vphoned spells it.
AUTO_LOCK_NEVER = 2147483647

# Package managers by the identifiers their repositories publish, most
# likely first. Cydia has no rootless or roothide build: it needs a rootful
# jailbreak, which no vphone guest uses.
MANAGERS = {
    "sileo": ["org.coolstar.sileo", "sileo"],
    "zebra": ["xyz.willy.zebra", "zebra"],
}
UNSUPPORTED_MANAGERS = {
    "cydia": "Cydia only runs on rootful jailbreaks; vphone guests are roothide or "
             "rootless. Use Sileo or Zebra, which read the same repositories.",
}

# Irisin's own recommendations for roothide (its default-list-iphoneos-arm64e.plist
# in 5.0.3), which its welcome screens offer. The Procursus line is where dpkg,
# bash and apt come from.
ROOTHIDE_REPOSITORIES = [
    "https://roothide.github.io",
    "deb https://roothide.github.io/procursus iphoneos-arm64e/1900 main",
    "https://apt.owngoal.dev",
]


class Guest:
    """vphoned over the VM's host control socket."""

    def __init__(self, call, path):
        self._call = call
        self._path = path

    def rpc(self, method, params=None, check=True):
        reply = self._call(self._path, {"t": "rpc", "method": method, "params": params or {}, "screen": False})
        if check and not reply.get("ok"):
            raise SystemExit(f"{method} failed: {reply.get('error')}")
        return reply.get("result") if reply.get("ok") else None

    def script(self, source, timeout=120):
        """Runs JavaScript in a vphoned session; returns its result text."""
        result = self.rpc("script.eval", {"source": source, "timeout": timeout})
        if not result.get("ok"):
            raise SystemExit(f"guest script failed: {result.get('error')}\n{result.get('output', '')}")
        return result.get("result")

    def run(self, path, args, timeout=600):
        """Runs one program as root; returns (status, stdout, stderr)."""
        source = (
            f"var r = proc.run({json.dumps(path)}, {json.dumps(args)}, '');"
            "JSON.stringify({s: r.status, o: String(r.stdout || ''), e: String(r.stderr || '')})"
        )
        reply = json.loads(self.script(source, timeout))
        return reply["s"], reply["o"], reply["e"]

    def exists(self, path):
        parent, name = path.rstrip("/").rsplit("/", 1)
        listing = self.rpc("files.list", {"path": parent}, check=False) or {}
        return any(entry.get("name") == name for entry in listing.get("entries", []))


def say(text):
    print(f"[duo] {text}", flush=True)


# MARK: - Appearance

def appearance(guest, choice):
    if choice in APPEARANCES:
        guest.rpc("settings.set", {"domain": APPEARANCE_DOMAIN, "key": APPEARANCE_KEY,
                                   "value": APPEARANCES[choice], "type": "int"})
        say(f"iOS appearance: {choice}")
        return
    values = (guest.rpc("settings.get", {"domain": APPEARANCE_DOMAIN}) or {}).get("values", {})
    mode = (values.get(APPEARANCE_KEY) or {}).get("value", 1)
    print("dark" if mode == 2 else "light")


# MARK: - Profiles

def developer(guest):
    """Developer Mode, Setup Assistant out of the way, and a screen that stays on."""
    status = guest.rpc("developer_mode.status") or {}
    if status.get("enabled"):
        say("Developer Mode: already on")
    else:
        guest.rpc("developer_mode.enable")
        say("Developer Mode: turned on (iOS may ask to restart to finish)")
    setup = guest.rpc("setup.status", check=False) or {}
    if setup.get("completed") is False or setup.get("running"):
        guest.rpc("setup.skip")
        say("Setup Assistant: skipped")
    guest.rpc("display.auto_lock.set", {"seconds": AUTO_LOCK_NEVER})
    say("Auto-Lock: Never (applied by iOS within a few seconds)")


def bootstrap(guest, layout):
    state = guest.rpc("bootstrap.inspect") or {}
    if state.get("installed"):
        say(f"bootstrap: already installed at {', '.join(map(str, state.get('roots', [])))}")
        return jbroot(guest)
    guest.rpc("bootstrap.install", {"layout": layout})
    say(f"bootstrap: installing Irisin ({layout})")
    for _ in range(120):
        status = guest.rpc("bootstrap.status") or {}
        if status.get("phase") == "completed":
            say(f"bootstrap: Irisin {status.get('version')} at {status.get('jbroot')}")
            return status.get("jbroot")
        if status.get("phase") == "failed":
            raise SystemExit(f"bootstrap failed: {status.get('error')}")
        time.sleep(3)
    raise SystemExit("bootstrap did not finish in 6 minutes; see `vphone-duo rpc bootstrap.status`")


def jbroot(guest):
    info = guest.rpc("device.info") or {}
    root = (info.get("jailbreak") or {}).get("jbroot")
    if root:
        return root
    status = guest.rpc("bootstrap.status", check=False) or {}
    return status.get("jbroot")


def apt_root(root):
    """Where the bootstrap's programs live: under the jbroot for roothide, /var/jb for rootless."""
    return root.rstrip("/")


def wait_for_base(guest, root, minutes):
    apt = f"{apt_root(root)}/usr/bin/apt-get"
    if guest.exists(apt):
        return True
    say("one step in Irisin is left, the only one with no API (see guest-layout.md):")
    say("  1. Open Irisin. On its welcome screens, add the recommended repositories:")
    for repository in ROOTHIDE_REPOSITORIES:
        say(f"       {repository}")
    say("  2. Search for 'OwnGoal Bootstrap for vphone' and add it to the queue.")
    say("  3. Long-press Execute and choose Bootstrap Install.")
    if minutes <= 0:
        say("then run this profile again to finish.")
        return False
    say(f"waiting up to {minutes} minutes for apt to appear...")
    deadline = time.time() + minutes * 60
    while time.time() < deadline:
        time.sleep(10)
        if guest.exists(apt):
            say("apt is installed")
            return True
    say("apt has not appeared yet; run this profile again once Bootstrap Install is done.")
    return False


def apt(guest, root, *arguments):
    """apt-get through the bootstrap's own login shell, so PATH and the jbroot are its own."""
    command = "apt-get -y -o Dpkg::Options::=--force-confold " + " ".join(arguments)
    return guest.run(f"{apt_root(root)}/usr/bin/bash", ["-lc", command], timeout=900)


def install_manager(guest, root, name):
    if name in UNSUPPORTED_MANAGERS:
        say(f"{name}: not installed. {UNSUPPORTED_MANAGERS[name]}")
        return
    status, out, err = apt(guest, root, "update")
    if status != 0:
        raise SystemExit(f"apt-get update failed:\n{err or out}")
    for identifier in MANAGERS[name]:
        status, out, err = guest.run(f"{apt_root(root)}/usr/bin/bash", ["-lc", f"apt-cache show {identifier}"])
        if status == 0 and out.strip():
            status, out, err = apt(guest, root, "install", identifier)
            if status != 0:
                raise SystemExit(f"installing {identifier} failed:\n{err or out}")
            guest.rpc("system.uicache", check=False)
            say(f"{name}: installed ({identifier})")
            return
    say(f"{name}: no package found in the added repositories; add its repository in Irisin and run again")


def install_ssh_key(guest, root, key_path):
    key = open(os.path.expanduser(key_path)).read().strip()
    if not key.startswith(("ssh-", "ecdsa-", "sk-")) or "PRIVATE" in key:
        raise SystemExit(f"{key_path} is not an SSH public key")
    # The bootstrap's sshd may resolve mobile's home inside or outside the
    # jbroot, so the key goes to both; each is mobile's, 0700 and 0600.
    homes = ["/var/mobile", f"{apt_root(root)}/var/mobile"]
    paths = json.dumps([f"{home}/.ssh" for home in homes])
    source = f"""
var fm = ObjC.use('NSFileManager').defaultManager();
var owner = ObjC.use('NSMutableDictionary').dictionary();
owner.setObject_forKey_(501, 'NSFileOwnerAccountID');
owner.setObject_forKey_(501, 'NSFileGroupOwnerAccountID');
var done = [];
{paths}.forEach(function (dir) {{
  fm.createDirectoryAtPath_withIntermediateDirectories_attributes_error_(dir, true, null, null);
  var file = dir + '/authorized_keys';
  var existing = ObjC.use('NSString').stringWithContentsOfFile_encoding_error_(file, 4, null);
  var text = existing ? String(existing) : '';
  var key = {json.dumps(key)};
  if (text.indexOf(key) < 0) text = text + (text && text.slice(-1) !== '\\n' ? '\\n' : '') + key + '\\n';
  ObjC.use('NSString').stringWithString_(text).writeToFile_atomically_encoding_error_(file, true, 4, null);
  [dir, file].forEach(function (p) {{ fm.setAttributes_ofItemAtPath_error_(owner, p, null); }});
  fm.setAttributes_ofItemAtPath_error_(ObjC.use('NSDictionary').dictionaryWithObject_forKey_(448, 'NSFilePosixPermissions'), dir, null);
  fm.setAttributes_ofItemAtPath_error_(ObjC.use('NSDictionary').dictionaryWithObject_forKey_(384, 'NSFilePosixPermissions'), file, null);
  done.push(file);
}});
done.join(', ')
"""
    say(f"ssh: key added to {guest.script(source)}")
    say("ssh: connect through usbmuxd, e.g.  iproxy 2222 22 -u <UDID> &  ssh -p 2222 mobile@127.0.0.1")


def jailbreak(guest, layout, manager, ssh_key, wait_minutes):
    developer(guest)
    root = bootstrap(guest, layout)
    if not root:
        raise SystemExit("could not find the bootstrap's root; see `vphone-duo rpc bootstrap.inspect`")
    if not wait_for_base(guest, root, wait_minutes):
        return
    if manager and manager != "none":
        install_manager(guest, root, manager)
    if ssh_key:
        install_ssh_key(guest, root, ssh_key)
    say("jb profile: done")


def custom(guest, config_path):
    with open(os.path.expanduser(config_path)) as handle:
        config = json.load(handle)
    unknown = set(config) - {"developer", "appearance", "auto_lock", "bootstrap", "manager",
                             "packages", "ssh_key", "wait_minutes"}
    if unknown:
        raise SystemExit(f"unknown keys in {config_path}: {', '.join(sorted(unknown))}")
    if config.get("developer"):
        developer(guest)
    if "auto_lock" in config:
        seconds = AUTO_LOCK_NEVER if config["auto_lock"] == "never" else int(config["auto_lock"])
        guest.rpc("display.auto_lock.set", {"seconds": seconds})
        say(f"Auto-Lock: {config['auto_lock']}")
    if config.get("appearance"):
        appearance(guest, config["appearance"])
    layout = config.get("bootstrap")
    if not layout:
        return
    root = bootstrap(guest, layout)
    if not wait_for_base(guest, root, int(config.get("wait_minutes", 0))):
        return
    if config.get("manager"):
        install_manager(guest, root, config["manager"])
    packages = config.get("packages") or []
    if packages:
        status, out, err = apt(guest, root, "install", *packages)
        if status != 0:
            raise SystemExit(f"installing {', '.join(packages)} failed:\n{err or out}")
        guest.rpc("system.uicache", check=False)
        say(f"packages: installed {', '.join(packages)}")
    if config.get("ssh_key"):
        install_ssh_key(guest, root, config["ssh_key"])
    say("custom profile: done")


def status(guest):
    info = guest.rpc("device.info") or {}
    jb = info.get("jailbreak") or {}
    developer_mode = info.get("developer_mode") or {}
    root = jb.get("jbroot")
    print(json.dumps({
        "model": info.get("model"),
        "developer_mode": developer_mode.get("enabled"),
        "bootstrap": jb.get("layout"),
        "jbroot": root,
        "apt": guest.exists(f"{root}/usr/bin/apt-get") if root else False,
        "sshd": guest.exists(f"{root}/usr/sbin/sshd") if root else False,
    }, indent=2))


def run(call, path, args):
    """`vphone-duo setup ...` and `vphone-duo appearance ...`."""
    import argparse
    guest = Guest(call, path)
    if args and args[0] == "appearance":
        appearance(guest, args[1] if len(args) > 1 else "status")
        return
    parser = argparse.ArgumentParser(prog="vphone-duo setup")
    parser.add_argument("profile", choices=["dev", "jb", "custom", "status"])
    parser.add_argument("config", nargs="?", help="the JSON file, for custom")
    parser.add_argument("--layout", choices=["roothide", "rootless"], default="roothide")
    parser.add_argument("--manager", choices=["sileo", "zebra", "cydia", "none"], default="sileo")
    parser.add_argument("--ssh-key", help="a public key to authorize for mobile, e.g. ~/.ssh/id_ed25519.pub")
    parser.add_argument("--wait", type=int, default=20, metavar="MIN",
                        help="minutes to wait for Irisin's Bootstrap Install (0: do not wait)")
    options = parser.parse_args(args)
    if options.profile == "dev":
        developer(guest)
    elif options.profile == "jb":
        jailbreak(guest, options.layout, options.manager, options.ssh_key, options.wait)
    elif options.profile == "custom":
        if not options.config:
            parser.error("custom needs a JSON file")
        custom(guest, options.config)
    else:
        status(guest)

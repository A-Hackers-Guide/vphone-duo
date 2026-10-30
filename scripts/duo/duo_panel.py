"""Boot an iPhone Duo guest on its inner or its cover panel.

A VM has one display, so iOS lays out for one panel per boot. `inner` makes
it the inner panel, as the Simulator's iPhone Duo describes it:

- the guest's device tree gets both panels, the inner one first
  (`cfw patch-dt-iphone-product --panels`, then duo_inner_tree.py), since
  QuartzCore takes the panel at the framebuffer's index, 0;
- `display-uuid` in the machine folder gives the display the inner panel's
  framebuffer-identifier, which iOS matches to that panel;
- the screen becomes the inner panel's 2007 x 2853.

`cover` puts back the device tree saved the first time (`devicetree.cover.img4`
in the machine folder), removes `display-uuid` and restores 1398 x 2034.

The machine must be stopped. Its Preboot volume is mounted without owners, so
no password is needed. `cfw update-environment` (and `vm set-bundle
--update-environment`) rebuild the device tree: run `panel inner` again after.
"""
import glob
import json
import os
import plistlib
import shutil
import subprocess
import sys
import tempfile

INNER_IDENTIFIER = "BF0DC480-5EE2-4EC1-B02B-C75E94759832"
SIZES = {"inner": (2007, 2853), "cover": (1398, 2034)}
HERE = os.path.dirname(os.path.abspath(__file__))


def run(*args, **kwargs):
    return subprocess.run(args, check=True, capture_output=True, text=True, **kwargs).stdout


def machine_dir(name):
    return os.path.expanduser(os.path.join("~/.vphone/machines", name))


def vphone_cli(machine):
    """The vphone-cli of the bundle the machine is bound to."""
    with open(os.path.join(machine, "launchpad.json")) as f:
        version = json.load(f).get("bundle")
    path = f"/Library/Application Support/vphone-launchpad/Bundles/{version}/VPhone.bundle/Contents/MacOS/vphone-cli"
    if not os.path.exists(path):
        raise SystemExit(f"vphone-cli not found for bundle {version}")
    return path


def board_tree(machine):
    found = glob.glob(os.path.join(machine, "FirmwareOriginals/*/Firmware/all_flash/DeviceTree.v68ap.im4p"))
    if not found:
        raise SystemExit("no iPhone Duo device tree (DeviceTree.v68ap.im4p) in FirmwareOriginals")
    return found[0]


class Preboot:
    """The machine's Preboot volume, mounted read-write without owners."""

    def __init__(self, machine):
        self.disk = os.path.join(machine, "Disk.img")
        self.whole = None
        self.mount = tempfile.mkdtemp(prefix="vphone-preboot-")

    def __enter__(self):
        out = run("hdiutil", "attach", "-imagekey", "diskimage-class=CRawDiskImage", "-nomount", "-plist", self.disk)
        entities = plistlib.loads(out.encode())["system-entities"]
        self.whole = min((e["dev-entry"] for e in entities), key=len)
        try:
            # The partition holding the APFS container (Apple_APFS).
            store = next(e["dev-entry"] for e in entities
                         if "7C3457EF-0000-11AA-AA11-00306543ECAC" in (e.get("content-hint"), e.get("unmapped-content-hint"))
                         or e.get("content-hint") == "Apple_APFS")
            listing = plistlib.loads(run("diskutil", "apfs", "list", "-plist").encode())
            volume = None
            for container in listing["Containers"]:
                if any(s["DeviceIdentifier"] == os.path.basename(store) for s in container["PhysicalStores"]):
                    volume = next((v["DeviceIdentifier"] for v in container["Volumes"]
                                   if "Preboot" in v.get("Roles", [])), None)
            if not volume:
                raise SystemExit("no Preboot volume in the machine's disk")
            run("mount", "-t", "apfs", "-o", "nobrowse,noowners", f"/dev/{volume}", self.mount)
            trees = glob.glob(os.path.join(self.mount, "*/usr/standalone/firmware/devicetree.img4"))
            if len(trees) != 1:
                raise SystemExit(f"expected one devicetree.img4 in Preboot, found {len(trees)}")
            self.tree = trees[0]
        except BaseException:
            self.__exit__()
            raise
        return self

    def __exit__(self, *exc):
        subprocess.run(["umount", self.mount], capture_output=True)
        if self.whole:
            subprocess.run(["hdiutil", "detach", self.whole], capture_output=True)
        os.rmdir(self.mount)


def set_screen(machine, width, height):
    path = os.path.join(machine, "config.plist")
    with open(path, "rb") as f:
        config = plistlib.load(f)
    config["screenConfig"]["width"] = width
    config["screenConfig"]["height"] = height
    with open(path, "wb") as f:
        plistlib.dump(config, f)


def switch(name, panel):
    machine = machine_dir(name)
    if os.path.exists(os.path.join(machine, "vphone.sock")):
        import socket
        try:
            socket.socket(socket.AF_UNIX).connect(os.path.join(machine, "vphone.sock"))
            raise SystemExit(f"{name} is running; stop it first")
        except (ConnectionRefusedError, FileNotFoundError):
            pass
    saved = os.path.join(machine, "devicetree.cover.img4")
    uuid_file = os.path.join(machine, "display-uuid")
    with Preboot(machine) as preboot:
        if panel == "inner":
            if not os.path.exists(saved):
                shutil.copyfile(preboot.tree, saved)
            work = tempfile.mkdtemp(prefix="vphone-duo-tree-")
            try:
                grafted = os.path.join(work, "panels.img4")
                shutil.copyfile(saved, grafted)
                run(vphone_cli(machine), "cfw", "patch-dt-iphone-product", grafted, board_tree(machine), "--panels")
                inner = os.path.join(work, "inner.img4")
                run(sys.executable, "-I", os.path.join(HERE, "duo_inner_tree.py"), grafted, inner)
                shutil.copyfile(inner, preboot.tree)
            finally:
                shutil.rmtree(work)
        else:
            if not os.path.exists(saved):
                raise SystemExit("no saved cover device tree; the machine was not switched to inner here")
            shutil.copyfile(saved, preboot.tree)
    if panel == "inner":
        with open(uuid_file, "w") as f:
            f.write(INNER_IDENTIFIER + "\n")
    elif os.path.exists(uuid_file):
        os.remove(uuid_file)
    set_screen(machine, *SIZES[panel])
    print(f"{name}: boots on the {panel} panel ({SIZES[panel][0]} x {SIZES[panel][1]})")

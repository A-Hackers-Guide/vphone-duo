#!/bin/zsh
# fw_send_testing_ramdisk.sh — Send testing boot chain to device via irecovery.
#
# Usage: ./fw_send_testing_ramdisk.sh [testing_ramdisk_dir]
#
# Expects device in DFU mode. Loads iBSS/iBEC, then boots with
# SPTM, TXM, device tree, SEP, and kernel. No ramdisk or trustcache.
# Kernel will panic after boot (no rootfs — expected).
set -euo pipefail

IRECOVERY="${IRECOVERY:-irecovery}"
RAMDISK_DIR="${1:-TestingRamdisk}"

if [[ ! -d "$RAMDISK_DIR" ]]; then
    echo "[-] Testing ramdisk directory not found: $RAMDISK_DIR"
    echo "    Run 'make testing_ramdisk_build' first."
    exit 1
fi

echo "[*] Sending testing boot chain from $RAMDISK_DIR ..."
echo "    (no rootfs — kernel will panic after boot)"

# 1. Load iBSS + iBEC (DFU → recovery)
echo "  [1/6] Loading iBSS..."
"$IRECOVERY" -f "$RAMDISK_DIR/iBSS.vresearch101.RELEASE.img4"

echo "  [2/6] Loading iBEC..."
"$IRECOVERY" -f "$RAMDISK_DIR/iBEC.vresearch101.RELEASE.img4"
"$IRECOVERY" -c go

sleep 1

# 2. Load SPTM
echo "  [3/6] Loading SPTM..."
"$IRECOVERY" -f "$RAMDISK_DIR/sptm.vresearch1.release.img4"
"$IRECOVERY" -c firmware

# 3. Load TXM
echo "  [4/6] Loading TXM..."
"$IRECOVERY" -f "$RAMDISK_DIR/txm.img4"
"$IRECOVERY" -c firmware

# 4. Load device tree
echo "  [5/6] Loading DeviceTree..."
"$IRECOVERY" -f "$RAMDISK_DIR/DeviceTree.vphone600ap.img4"
"$IRECOVERY" -c devicetree

# 5. Load SEP
echo "  [6/6] Loading SEP..."
"$IRECOVERY" -f "$RAMDISK_DIR/sep-firmware.vresearch101.RELEASE.img4"
"$IRECOVERY" -c firmware

# 6. Load kernel and boot
echo "  [*] Booting kernel..."
"$IRECOVERY" -f "$RAMDISK_DIR/krnl.img4"
"$IRECOVERY" -c bootx

echo "[+] Boot sequence sent. Kernel should boot and then panic (no rootfs)."

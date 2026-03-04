#!/usr/bin/env zsh
set -euo pipefail

# ─── Track child PIDs for cleanup ───────────────────────────────────
typeset -a CHILD_PIDS=()

cleanup() {
    echo "\n[testing_do] cleaning up..."
    for pid in "${CHILD_PIDS[@]}"; do
        if kill -0 "$pid" 2>/dev/null; then
            echo "[testing_do] killing PID $pid"
            kill -9 "$pid" 2>/dev/null || true
        fi
    done
    exit 0
}

trap cleanup EXIT INT TERM

PROJECT_DIR="$(cd "$(dirname "${0:a:h}")" && pwd)"
cd "$PROJECT_DIR"

# ─── Kill existing vphone-cli ──────────────────────────────────────
echo "[testing_do] killing existing vphone-cli..."
pkill -9 vphone-cli 2>/dev/null || true
sleep 1

# ─── Build pipeline ───────────────────────────────────────────────
echo "[testing_do] fw_prepare..."
make fw_prepare

echo "[testing_do] fw_patch_jb..."
make fw_patch_jb

echo "[testing_do] testing_ramdisk_build..."
make testing_ramdisk_build

# ─── Send ramdisk in background ───────────────────────────────────
echo "[testing_do] testing_ramdisk_send (background)..."
make testing_ramdisk_send &
CHILD_PIDS+=($!)

# ─── Boot DFU ─────────────────────────────────────────────────────
echo "[testing_do] boot_dfu..."
make boot_dfu &
CHILD_PIDS+=($!)

echo "[testing_do] waiting for boot_dfu (PID ${CHILD_PIDS[-1]})..."
wait "${CHILD_PIDS[-1]}" 2>/dev/null || true

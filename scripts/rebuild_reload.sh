#!/usr/bin/env bash
# sudo ./rebuild_reload.sh   — rebuild nvidia-srv DKMS for running kernel and reload modules
set -euo pipefail
VER=580.159.03; K=$(uname -r)
echo "== ensure no GPU users =="
if fuser /dev/nvidia* 2>/dev/null; then echo "ERROR: GPU in use, aborting"; fuser -v /dev/nvidia* ; exit 1; fi
echo "== dkms remove ($K) =="; dkms remove nvidia-srv/$VER -k "$K" || true
echo "== dkms build  ($K) =="; dkms build  nvidia-srv/$VER -k "$K"
echo "== dkms install($K) =="; dkms install nvidia-srv/$VER -k "$K"
echo "== unload modules =="
rmmod nvidia_uvm nvidia_drm nvidia_modeset nvidia 2>/dev/null || true
# nvidia may still be ref'd; retry
for m in nvidia_uvm nvidia_drm nvidia_modeset nvidia; do rmmod $m 2>/dev/null || true; done
echo "== load modules =="
modprobe nvidia && modprobe nvidia_uvm
echo "== verify =="
nvidia-smi --query-gpu=name,driver_version --format=csv,noheader
cat /proc/driver/nvidia/version | head -1

#!/usr/bin/env bash
# Apply the DEVDAX kernel-glue patches to the installed nvidia-srv 580.159.03 source.
# Usage: sudo ./scripts/apply_patch.sh [SRC_DIR]
set -euo pipefail
SRC="${1:-/usr/src/nvidia-srv-580.159.03/nvidia}"
HERE="$(cd "$(dirname "$0")" && pwd)"
PATCH="$HERE/../patches/nvidia-srv-580.159.03-devdax.patch"
echo "Applying $PATCH to $SRC"
patch -p1 -d "$SRC" < "$PATCH"
echo "Done. Rebuild + reload with: sudo $HERE/rebuild_reload.sh"

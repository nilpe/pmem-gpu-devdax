#!/usr/bin/env bash
# run_stage.sh <label> <use_hook 0|1> <note> [max_gib]
set -uo pipefail
cd "$(dirname "$0")"
LABEL="${1:?label}"; HOOK="${2:-0}"; NOTE="${3:-}"; MAX="${4:-}"
DEV=/dev/dax0.1
LOG="results/${LABEL}.log"
PRE=""; [ "$HOOK" = "1" ] && PRE="LD_PRELOAD=$PWD/libsysinfo_hook.so"
echo "### run_stage $LABEL  hook=$HOOK  max=${MAX:-device}  $(date)" | tee "$LOG"
eval $PRE ./dax_pin_bisect "$DEV" ${MAX:+$MAX} 2>&1 | tee -a "$LOG"
BEST=$(grep -oE 'Best successful size: [0-9]+ bytes \(([0-9.]+) GiB\)' "$LOG" | grep -oE '\(([0-9.]+) GiB' | grep -oE '[0-9.]+' | tail -1)
[ -z "$BEST" ] && BEST=0
INST=$(awk -v b=$(cat /sys/bus/dax/devices/dax0.1/size) 'BEGIN{printf "%.2f", b/1073741824}')
./stage_slide "$LABEL" "$INST" "$BEST" "$DEV" "$NOTE" | tee "results/${LABEL}.slide.txt"

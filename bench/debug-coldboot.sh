#!/bin/sh
# Wait for the next cold boot, then characterise it. Run from the HOST.
#
#   sh bench/debug-coldboot.sh [camera-index]
#
# Answers the question the benchmark raised but cannot: WHY is the CCI I2C bus
# dead for the first ~90 seconds of a cold boot, and does it ever come back?
#
# It waits for a power cycle, then from the moment SSH answers it probes the
# panel controller at 0x45 from USERSPACE every few seconds. That separates two
# very different explanations:
#
#   * if userspace transfers also fail, the bus really is down and the fix has
#     to make the kernel's enable path survive it
#   * if userspace transfers succeed while the kernel driver logged failures,
#     the bus is fine and the problem is in the driver's timing or its retry
#     window - a completely different fix
#
# Then, if the panel came up dark, it runs probe-recovery.py to find out which
# action rescues it.
set -eu
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
CAMERA=${1:-1}
OUT="$HERE/coldboot-debug.log"

say() { printf '%s  %s\n' "$(date +%H:%M:%S)" "$*" | tee -a "$OUT"; }

up() { sh "$HERE/remote.sh" 'echo up' >/dev/null 2>&1; }

: > "$OUT"
say "waiting for the board to go DOWN (unplug it now)"
misses=0
while [ "$misses" -lt 2 ]; do
    if up; then misses=0; else misses=$((misses + 1)); fi
    sleep 3
done
say "power-down detected; waiting for it to come back"

while ! up; do sleep 3; done
say "board is up - probing the I2C bus from userspace as early as possible"

# Poll the panel controller directly. 0x80 is REG_ID, a harmless read.
sh "$HERE/remote.sh" '
for i in $(seq 1 40); do
    T=$(cut -d. -f1 /proc/uptime)
    R=$(i2ctransfer -y -f 0 w1@0x45 0x80 r1 2>&1 | tr -d "\n")
    case "$R" in 0x*) S=ok;; *) S=FAIL;; esac
    N=$(dmesg 2>/dev/null | grep -c "cci.*timeout")
    A=$(dmesg 2>/dev/null | grep -c "attiny:.*failed")
    echo "uptime=${T}s i2c_0x45=$S cci_timeouts=$N attiny_failures=$A"
    sleep 3
done' 2>&1 | tee -a "$OUT"

say "userspace probe finished; checking what the panel looks like"
python "$HERE/optical.py" check --camera "$CAMERA" 2>/dev/null | tee -a "$OUT"

if python "$HERE/optical.py" check --camera "$CAMERA" --expect image >/dev/null 2>&1; then
    say "the panel came up FINE this boot - nothing to recover."
    say "Power-cycle again to catch a dark one."
else
    say "panel is dark - probing which action recovers it"
    python "$HERE/probe-recovery.py" --camera "$CAMERA" 2>&1 | tee -a "$OUT"
fi

say "done - full log in $OUT"

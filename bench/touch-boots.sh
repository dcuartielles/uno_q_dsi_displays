#!/bin/sh
# Measure whether the touchscreen survives a boot, over N warm reboots.
#
#   bench/touch-boots.sh 8 > bench/results/touch/<label>.log
#
# Why warm reboots, when everything else here insists on cold ones
# ----------------------------------------------------------------
# The dark-panel half of this bug needs a real power cycle: the backlight
# enable path only misbehaves from cold. The touch half does not. The wedge
# that loses the touchscreen is caused by the drivers' own I2C traffic as they
# load, so a plain `systemctl reboot` reproduces it - measured at roughly 2 in
# 3 boots on a Waveshare panel.
#
# That makes this cheap enough to run between edits, with no smart plug and
# nobody at the socket. Cold-boot numbers still belong in RESULTS.md; these do
# not, and mixing the two would misstate both.
#
# Disable the recovery service first
# ----------------------------------
# Otherwise it rebinds the touch driver after ~100 s and every boot looks like
# a success, whatever the driver did. The question this answers is precisely
# whether the driver copes on its own:
#
#   sudo systemctl disable uno-q-dsi-panel-recover.service
#   # ... measure ...
#   sudo systemctl enable uno-q-dsi-panel-recover.service   # PUT IT BACK
#
# Columns
# -------
#   timeouts   CCI I2C timeouts this boot. The wedge, in one number. Boots in
#              single digits did not hit the bug and prove nothing either way.
#   deferred   the driver postponed bring-up rather than failing outright
#   touch      is there a touch input device at the end
#   bound-at   uptime when the input device appeared
set -eu

N=${1:-8}
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPO=$(CDPATH= cd -- "$HERE/.." && pwd)
cd "$REPO"

r() { sh bench/remote.sh "$1" 2>/dev/null | tr -d '\r'; }

num() { case "$1" in ''|*[!0-9]*) echo 0 ;; *) echo "$1" ;; esac; }

printf '%-5s %-9s %-9s %-6s %-10s %s\n' boot timeouts deferred touch bound-at note

i=1
while [ "$i" -le "$N" ]; do
    r 'sync; systemctl reboot' >/dev/null 2>&1 || true
    sleep 30

    w=0
    while [ "$w" -lt 40 ]; do
        r 'echo up' | grep -q up && break
        w=$((w + 1)); sleep 5
    done
    if [ "$w" -ge 40 ]; then
        printf '%-5s %s\n' "$i" "board did not come back"
        i=$((i + 1)); continue
    fi

    # Wait past the driver's own retry deadline, so a late success still counts
    # as one. Scoring before the window closes would credit the fix with
    # failures it was still working on.
    while :; do
        up=$(num "$(r 'cut -d. -f1 < /proc/uptime')")
        [ "$up" -ge 170 ] && break
        sleep 10
    done

    to=$(num "$(r 'dmesg | grep -ci "i2c.*timeout\|cci.*timeout"' | head -1)")
    def=$(num "$(r 'dmesg | grep -c "finishing touchscreen setup in the background"' | head -1)")
    dev=$(num "$(r 'grep -c ft5x06 /proc/bus/input/devices' | head -1)")
    at=$(r 'dmesg | grep -m1 "input: generic ft5x06" | tr -d "[]" | awk "{print \$1}"' | head -1)
    late=$(r 'dmesg | grep -o "touchscreen came up [0-9]* ms into the retry window" | tail -1')
    fail=$(r 'dmesg | grep -o "touchscreen never answered: -[0-9]*\|touchscreen probe failed: -[0-9]*" | tail -1')

    note=$late
    [ -n "$fail" ] && note=$fail
    [ -z "$note" ] && [ "$def" != 0 ] && note="deferred, no outcome logged"

    printf '%-5s %-9s %-9s %-6s %-10s %s\n' \
        "$i" "$to" "$def" "$dev" "${at:-none}" "$note"
    i=$((i + 1))
done

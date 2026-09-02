#!/bin/sh
# Collect one boot's worth of panel health as JSON. Runs ON the board.
#
#   collect.sh            # emits a single JSON object on stdout
#
# Everything here is cheap and read-only. The benchmark runs it once per boot
# and stores the record; analyze.py then looks for what correlates with the
# boots that failed.
set -u

j_str() { printf '"%s"' "$(printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g')"; }

# ------------------------------------------------------------- identity ---
MODEL=$(tr -d '\0' < /proc/device-tree/model 2>/dev/null)
KERNEL=$(uname -r)
UPTIME=$(cut -d. -f1 /proc/uptime)
BOOT_ID=$(cat /proc/sys/kernel/random/boot_id 2>/dev/null)

# --------------------------------------------------------------- display ---
CONN=""; MODE=""
for s in /sys/class/drm/*/status; do
    [ -f "$s" ] || continue
    if [ "$(cat "$s" 2>/dev/null)" = "connected" ]; then
        CONN=$(basename "$(dirname "$s")")
        MODE=$(head -1 "$(dirname "$s")/modes" 2>/dev/null)
        break
    fi
done
FB=0; [ -e /dev/fb0 ] && FB=1
FBSIZE=$(cat /sys/class/graphics/fb0/virtual_size 2>/dev/null)
BL=$(ls /sys/class/backlight/ 2>/dev/null | head -1)
BL_BRIGHT=$(cat "/sys/class/backlight/$BL/brightness" 2>/dev/null)

# ---------------------------------------------------------------- touch ---
TOUCH=0
grep -qiE 'ft5x06|goodix' /proc/bus/input/devices 2>/dev/null && TOUCH=1
TOUCH_NAME=$(grep -iE 'Name=.*(ft5|goodix)' /proc/bus/input/devices 2>/dev/null \
             | head -1 | sed 's/.*Name="\(.*\)".*/\1/')

# -------------------------------------------------------------- drivers ---
drv() { # drv <address-substring>
    for d in /sys/bus/i2c/devices/*"$1"/driver /sys/bus/mipi-dsi/devices/*/driver; do
        [ -L "$d" ] || continue
        case "$d" in *"$1"*) basename "$(readlink "$d")"; return;; esac
    done
    echo ""
}
D_PANEL=""
for d in /sys/bus/mipi-dsi/devices/*/driver; do
    [ -L "$d" ] && D_PANEL=$(basename "$(readlink "$d")") && break
done
D_ATTINY=$(drv "-0045")
D_TOUCH=$(drv "-0038")

# ------------------------------------------------ the interesting counters ---
# These are what separate a good boot from a bad one. On a bad boot the CCI
# bus is dead for the first minute or so and these run into the hundreds.
CCI_TIMEOUTS=$(dmesg 2>/dev/null | grep -c 'cci.*timeout')
ATTINY_FAILS=$(dmesg 2>/dev/null | grep -c 'attiny:.*failed')
DSI_ERRORS=$(dmesg 2>/dev/null | grep -c 'dsi_err')
TOUCH_PROBE_FAIL=$(dmesg 2>/dev/null | grep -c 'edt_ft5x06.*probe failed')

# When the touch driver bound, and whether the recovery service had to step in.
TOUCH_PROBE_T=$(dmesg 2>/dev/null | sed -n 's/^\[ *\([0-9.]*\)\].*edt_ft5x06.*no IRQ, polling.*/\1/p' | head -1)
FIRST_CCI_T=$(dmesg 2>/dev/null | sed -n 's/^\[ *\([0-9.]*\)\].*cci.*timeout.*/\1/p' | head -1)
LAST_CCI_T=$(dmesg 2>/dev/null | sed -n 's/^\[ *\([0-9.]*\)\].*cci.*timeout.*/\1/p' | tail -1)
RECOVERED=0
journalctl -u uno-q-dsi-panel-recover --no-pager -o cat 2>/dev/null \
    | grep -q 'touch recovered' && RECOVERED=1
RECOVERY_RAN=0
journalctl -u uno-q-dsi-panel-recover --no-pager -o cat 2>/dev/null \
    | grep -q 'reload attempt' && RECOVERY_RAN=1

# --------------------------------------------------------------- verdict ---
# Software's best guess. The camera has the final say - software cannot tell a
# lit panel from a dark one.
SW_OK=0
[ -n "$CONN" ] && [ "$FB" = "1" ] && [ -n "$BL" ] && SW_OK=1

cat <<EOF
{
  "boot_id": $(j_str "$BOOT_ID"),
  "model": $(j_str "$MODEL"),
  "kernel": $(j_str "$KERNEL"),
  "uptime_s": ${UPTIME:-0},
  "connector": $(j_str "$CONN"),
  "mode": $(j_str "$MODE"),
  "fb0": $FB,
  "fb_size": $(j_str "$FBSIZE"),
  "backlight": $(j_str "$BL"),
  "backlight_brightness": ${BL_BRIGHT:-null},
  "touch_present": $TOUCH,
  "touch_name": $(j_str "$TOUCH_NAME"),
  "driver_panel": $(j_str "$D_PANEL"),
  "driver_attiny": $(j_str "$D_ATTINY"),
  "driver_touch": $(j_str "$D_TOUCH"),
  "cci_timeouts": ${CCI_TIMEOUTS:-0},
  "attiny_write_failures": ${ATTINY_FAILS:-0},
  "dsi_errors": ${DSI_ERRORS:-0},
  "touch_probe_failures": ${TOUCH_PROBE_FAIL:-0},
  "touch_bound_at_s": ${TOUCH_PROBE_T:-null},
  "first_cci_timeout_s": ${FIRST_CCI_T:-null},
  "last_cci_timeout_s": ${LAST_CCI_T:-null},
  "recovery_ran": $RECOVERY_RAN,
  "recovery_succeeded": $RECOVERED,
  "software_ok": $SW_OK
}
EOF

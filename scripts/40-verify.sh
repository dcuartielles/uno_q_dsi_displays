#!/bin/sh
# Post-reboot check. Reports what worked and what did not.
#   sudo ./scripts/40-verify.sh [panels/your-panel.panel]
#
# Passing the panel definition makes the check stricter: if the panel declares
# a touch controller, a missing touch device is reported as a failure rather
# than as a note.
HERE=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
. "$HERE/lib/common.sh"

TOUCH_ADDR=
if [ -n "$1" ] && [ -f "$1" ]; then
    load_panel "$(abspath "$1")"
fi

FAIL=0
check() { # check <description> <condition-result> [detail]
    if [ "$2" = "0" ]; then ok "$1${3:+  ($3)}"
    else printf '%s FAIL%s %s%s\n' "$C_RED" "$C_OFF" "$1" "${3:+  ($3)}"; FAIL=$((FAIL+1)); fi
}

step "System"
say "  model  : $(tr -d '\0' < /proc/device-tree/model 2>/dev/null)"
say "  kernel : $(uname -r)"

step "Carrier configuration"
arduino-linux-config carrier show 2>/dev/null | sed 's/^/  /' | head -6

step "Display pipeline"
CONN=$(for s in /sys/class/drm/*/status; do
    [ -f "$s" ] && [ "$(cat "$s")" = "connected" ] && basename "$(dirname "$s")"
done | head -1)
[ -n "$CONN" ]; check "a DRM connector is connected" $? "${CONN:-none}"

if [ -n "$CONN" ]; then
    MODE=$(tr '\n' ' ' < "/sys/class/drm/$CONN/modes" 2>/dev/null)
    [ -n "$MODE" ]; check "connector reports a mode" $? "$MODE"
fi

[ -e /dev/fb0 ]; check "framebuffer /dev/fb0 exists" $? \
    "$(cat /sys/class/graphics/fb0/virtual_size 2>/dev/null)"

BL=$(ls /sys/class/backlight/ 2>/dev/null | head -1)
[ -n "$BL" ]; check "backlight registered" $? "${BL:-none}"

DSIERR=$(dmesg 2>/dev/null | grep -c dsi_err)
[ "$DSIERR" -eq 0 ]; check "no DSI errors" $? "$DSIERR"

step "Drivers bound"
for d in /sys/bus/mipi-dsi/devices/*/driver; do
    [ -L "$d" ] && say "  $(basename "$(dirname "$d")") -> $(basename "$(readlink "$d")")"
done
for d in /sys/bus/i2c/devices/*/driver; do
    [ -L "$d" ] && say "  $(basename "$(dirname "$d")") -> $(basename "$(readlink "$d")")"
done

step "Touch"
if grep -qi 'ft5x06\|goodix\|edt' /proc/bus/input/devices 2>/dev/null; then
    ok "touch input device present"
    grep -iE 'Name=|Handlers=' /proc/bus/input/devices | grep -iA1 'ft5\|goodix' | sed 's/^/  /'
    dmesg 2>/dev/null | grep -q 'no IRQ, polling' && say "  (polling mode - the carrier has no touch IRQ line)"
elif [ -n "$TOUCH_ADDR" ]; then
    # the panel definition says there is a touch controller, so this is a fault
    false; check "touch input device present" $? "panel declares touch at $TOUCH_ADDR"
    dmesg 2>/dev/null | grep -iE 'edt_ft5|goodix' | tail -3 | sed 's/^/  /'
    say "  see docs/TROUBLESHOOTING.md, \"Touch does not work\""
else
    warn "no touch input device (fine if your panel has no touch)"
    dmesg 2>/dev/null | grep -iE 'edt_ft5|goodix' | tail -3 | sed 's/^/  /'
fi

step "Summary"
if [ "$FAIL" -eq 0 ]; then
    ok "everything checks out"
    say ""
    say "Show a test pattern:   sudo ./scripts/test-display.sh"
    say "Test the touchscreen:  sudo ./scripts/test-touch.sh"
else
    warn "$FAIL check(s) failed - see docs/TROUBLESHOOTING.md"
fi
exit "$FAIL"

#!/bin/sh
# Report touch events for 20 seconds.
#   sudo ./scripts/test-touch.sh
HERE=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
. "$HERE/lib/common.sh"
need_root "$@"

have_cmd evtest || {
    say "installing evtest..."
    DEBIAN_FRONTEND=noninteractive apt-get -y install evtest >/dev/null 2>&1 \
        || die "could not install evtest"
}

DEV=$(grep -B5 -iE 'ft5x06|goodix|edt' /proc/bus/input/devices 2>/dev/null \
      | grep -o 'event[0-9]*' | head -1)
[ -n "$DEV" ] || DEV=$(grep -A5 -iE 'ft5x06|goodix|edt' /proc/bus/input/devices 2>/dev/null \
      | grep -o 'event[0-9]*' | head -1)
[ -n "$DEV" ] || die "no touchscreen input device found. Run scripts/40-verify.sh"

ok "touch device: /dev/input/$DEV"
step "Touch and drag on the panel for 20 seconds"
timeout 20 evtest "/dev/input/$DEV" 2>/dev/null > /tmp/uno-q-touch.log

N=$(grep -c '^Event: time' /tmp/uno-q-touch.log 2>/dev/null || echo 0)
say ""
say "  events captured: $N"
if [ "$N" -gt 0 ]; then
    ok "touch works"
    grep '^Event: time' /tmp/uno-q-touch.log \
        | grep -E 'ABS_MT_POSITION|BTN_TOUCH' | head -10 | sed 's/^/  /'
else
    warn "no events - did you touch the panel?"
    say  "  read errors, if any:"
    dmesg 2>/dev/null | grep -i 'Unable to fetch data' | tail -3 | sed 's/^/    /'
fi

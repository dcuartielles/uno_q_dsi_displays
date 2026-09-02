#!/bin/sh
# Install the boot-recovery service.
#
#   sudo ./scripts/35-install-recovery.sh panels/<your-panel>.panel
#
# Why this exists
# ---------------
# On some boots the Qualcomm CCI I2C bus is simply dead for the first minute or
# so: every transfer to the panel controller at 0x45 and the touch controller at
# 0x38 returns -ETIMEDOUT, the drivers give up, and you end up with no
# touchscreen (and, from a cold start, no panel either). On other boots of the
# very same image there are two timeouts in total and everything works.
#
# The drivers bind perfectly if they are simply asked again once the bus has
# settled. So this service waits for boot to finish, checks whether the panel
# and touchscreen actually came up, and reloads the touch driver if not.
#
# This is a workaround for flaky hardware timing, not a fix for a wrong
# configuration. If it reports a failure on every boot, the panel definition or
# the wiring is wrong - see docs/TROUBLESHOOTING.md.
set -e
HERE=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
. "$HERE/lib/common.sh"
need_root "$@"

PANEL_DEF=${1:?usage: $0 <panel definition>}
[ -f "$PANEL_DEF" ] || die "no such panel definition: $PANEL_DEF"
PANEL_DEF=$(abspath "$PANEL_DEF")
load_panel "$PANEL_DEF"

HELPER=/usr/local/libexec/uno-q-dsi-panel-recover
UNIT=/etc/systemd/system/uno-q-dsi-panel-recover.service
CONF=/etc/default/uno-q-dsi-panel

step "Installing the boot-recovery service"

cat > "$CONF" <<EOF
# Written by uno-q-dsi-panel. Read by $HELPER.
PANEL_ID="$PANEL_ID"
TOUCH_ADDR="$TOUCH_ADDR"
# How long to keep retrying, in seconds, measured from when the helper starts.
RECOVER_BUDGET_SECONDS=150
# How long to wait for the panel controller to become reachable before
# re-asserting the backlight. Bus outages of 87s have been measured.
BACKLIGHT_WAIT=150
EOF
ok "$CONF"

mkdir -p "$(dirname "$HELPER")"
cat > "$HELPER" <<'EOF'
#!/bin/sh
# Re-bind the panel drivers when a flaky-I2C boot left them unbound.
# Installed by uno-q-dsi-panel. Safe to run by hand at any time.
[ -r /etc/default/uno-q-dsi-panel ] && . /etc/default/uno-q-dsi-panel
: "${RECOVER_BUDGET_SECONDS:=150}"
: "${BACKLIGHT_WAIT:=150}"

log() { echo "uno-q-dsi-panel: $*"; }
have_cmd() { command -v "$1" >/dev/null 2>&1; }
uptime_s() { cut -d. -f1 /proc/uptime; }

have_touch() {
    grep -qiE 'ft5x06|goodix' /proc/bus/input/devices 2>/dev/null
}

have_display() {
    for s in /sys/class/drm/*/status; do
        [ -f "$s" ] || continue
        [ "$(cat "$s")" = "connected" ] && return 0
    done
    return 1
}

# ---------------------------------------------------------------------------
# Re-assert the backlight, ALWAYS.
#
# On a cold boot the CCI I2C bus is frequently dead for the first 30-90
# seconds. The panel controller's enable writes fail, and the one that matters
# is REG_PWM: the DSI link, the panel resets and the picture are all set up
# correctly, but the backlight PWM never gets written, so the screen stays
# black while every software check reports the display healthy. Measured over
# cold boots on the reference board, this happened 5 times out of 6.
#
# Nothing in software can detect it - the controller's registers do not read
# back, and DRM cheerfully reports a connected connector scanning out a
# framebuffer. It took a camera to see it at all.
#
# Rewriting brightness re-runs attiny_update_status(), which writes REG_PWM and
# retries ten times internally. By the time this service runs the bus has
# recovered, so the write lands and the picture appears. Verified on a dark
# boot: the panel went from dark to showing the login screen immediately.
#
# This runs unconditionally because it is harmless when the panel is already
# lit, and we have no way to tell whether it is.
# ---------------------------------------------------------------------------
# The panel controller's own I2C bus number is not stable across boots, so
# find it from sysfs rather than assuming - it has been 0, 1 and 2 on this
# board on different boots.
attiny_bus() {
    ls -d /sys/bus/i2c/devices/*-0045 2>/dev/null | head -1         | sed 's#.*/##; s/-.*//'
}

# Is the controller actually reachable? REG_ID (0x80) is a harmless read.
#
# This is the part the first version of this fix was missing. It re-asserted
# the backlight on a fixed timer, and on a bad boot that landed while the bus
# was still down - so the write failed exactly like the boot-time ones and the
# panel stayed dark. Probing first turns "hope the bus is back" into "know it
# is back".
attiny_reachable() {
    b=$(attiny_bus)
    [ -n "$b" ] || return 1
    i2ctransfer -y -f "$b" w1@0x45 0x80 r1 >/dev/null 2>&1
}

restore_backlight() {
    for bl in /sys/class/backlight/*/; do
        [ -d "$bl" ] || continue
        max=$(cat "$bl/max_brightness" 2>/dev/null) || continue
        cur=$(cat "$bl/brightness" 2>/dev/null)
        v=${cur:-$max}
        [ "$v" -gt 0 ] 2>/dev/null || v=$max
        # Unblank first: backlight_get_brightness() returns 0 while the device
        # is blanked, so writing brightness alone would push PWM=0 and leave
        # the panel dark no matter how healthy the bus is.
        printf '0' > "$bl/bl_power" 2>/dev/null
        # Writing through sysfs always calls update_status even when the value
        # is unchanged, which is exactly what we need.
        printf '%s' "$v" > "$bl/brightness" 2>/dev/null
        log "re-asserted backlight $(basename "$bl") (brightness $v)"
    done
}

if dmesg 2>/dev/null | grep -q 'attiny:.*failed'; then
    log "panel controller writes FAILED during boot - the screen is probably dark"
fi

# Wait for the controller to answer before touching it, then re-assert. Give
# it a generous window: measured bus outages have run to 87s from power-on.
if have_cmd i2ctransfer; then
    waited=0
    while [ "$waited" -lt "$BACKLIGHT_WAIT" ]; do
        attiny_reachable && break
        sleep 3
        waited=$((waited + 3))
    done
    if attiny_reachable; then
        [ "$waited" -gt 0 ] && log "panel controller answered after ${waited}s"
        restore_backlight
    else
        log "WARNING: panel controller still unreachable after ${waited}s"
        restore_backlight
    fi
else
    log "i2ctransfer not installed - re-asserting the backlight blind"
    restore_backlight
fi

if have_display; then
    log "display is up"
else
    log "WARNING: no DRM connector is connected."
    log "WARNING: the panel did not come up this boot. Try a power cycle;"
    log "WARNING: if it persists see docs/TROUBLESHOOTING.md."
fi

# Nothing more to do if this panel has no touch controller.
[ -n "$TOUCH_ADDR" ] || exit 0

if have_touch; then
    log "touch is up"
    exit 0
fi

# Budget measured from now, so at least one attempt always happens - including
# when this helper is run by hand long after boot.
start=$(uptime_s)
tries=0
while :; do
    tries=$((tries + 1))
    log "touch did not probe (flaky I2C); reload attempt $tries"
    modprobe -r edt_ft5x06 2>/dev/null || true
    sleep 2
    modprobe edt_ft5x06 2>/dev/null || true
    sleep 4
    if have_touch; then
        log "touch recovered after $tries attempt(s)"
        exit 0
    fi
    [ $(( $(uptime_s) - start )) -ge "$RECOVER_BUDGET_SECONDS" ] && break
    sleep 5
done

log "touch still absent after $tries attempt(s) - see docs/TROUBLESHOOTING.md"
exit 0
EOF
chmod 0755 "$HELPER"
ok "$HELPER"

cat > "$UNIT" <<EOF
[Unit]
Description=Recover the UNO Q DSI panel drivers after a flaky I2C boot
Documentation=https://github.com/dcuartielles/uno_q_dsi_displays
After=multi-user.target

[Service]
Type=oneshot
RemainAfterExit=yes
# Let the boot-time I2C storm pass before looking.
ExecStartPre=/bin/sleep 25
ExecStart=$HELPER

[Install]
WantedBy=multi-user.target
EOF
ok "$UNIT"

systemctl daemon-reload
systemctl enable uno-q-dsi-panel-recover.service >/dev/null 2>&1
record_state "recovery service installed"
ok "enabled - it will run on every boot"
say ""
say "  Check what it did:  journalctl -u uno-q-dsi-panel-recover"
say "  Run it by hand:     sudo $HELPER"

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
EOF
ok "$CONF"

mkdir -p "$(dirname "$HELPER")"
cat > "$HELPER" <<'EOF'
#!/bin/sh
# Re-bind the panel drivers when a flaky-I2C boot left them unbound.
# Installed by uno-q-dsi-panel. Safe to run by hand at any time.
[ -r /etc/default/uno-q-dsi-panel ] && . /etc/default/uno-q-dsi-panel
: "${RECOVER_BUDGET_SECONDS:=150}"

log() { echo "uno-q-dsi-panel: $*"; }
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
restore_backlight() {
    for bl in /sys/class/backlight/*/; do
        [ -d "$bl" ] || continue
        max=$(cat "$bl/max_brightness" 2>/dev/null) || continue
        cur=$(cat "$bl/brightness" 2>/dev/null)
        # Writing through sysfs always calls update_status, even when the value
        # is unchanged - which is exactly what we need here.
        [ -n "$cur" ] && [ "$cur" -gt 0 ] 2>/dev/null             && printf '%s' "$cur" > "$bl/brightness" 2>/dev/null             || printf '%s' "$max" > "$bl/brightness" 2>/dev/null
        log "re-asserted backlight $(basename "$bl") (brightness ${cur:-$max})"
    done
}

if dmesg 2>/dev/null | grep -q 'attiny:.*failed'; then
    log "panel controller writes FAILED during boot - the screen is probably dark"
fi
restore_backlight

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

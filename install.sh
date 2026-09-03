#!/bin/sh
# One-shot installer for a MIPI DSI panel on Arduino UNO Q + UNO Media Carrier.
#
#   sudo ./install.sh panels/waveshare-800x480.panel
#
# Safe to re-run. Reboots are left to you.
set -e
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
. "$HERE/lib/common.sh"
need_root "$@"

PANEL_DEF=$1
if [ -z "$PANEL_DEF" ]; then
    say "usage: sudo $0 <panel definition>"
    say ""
    say "available panel definitions:"
    for p in "$HERE"/panels/*.panel; do
        [ "$(basename "$p")" = "TEMPLATE.panel" ] && continue
        say "    $p"
    done
    say ""
    say "to add a new panel, copy panels/TEMPLATE.panel and see"
    say "docs/ADDING-A-PANEL.md"
    exit 1
fi
[ -f "$PANEL_DEF" ] || die "no such panel definition: $PANEL_DEF"
load_panel "$PANEL_DEF"

step "uno-q-dsi-panel installer"
say "  panel      : $PANEL_ID"
say "  compatible : $PANEL_COMPATIBLE"
say "  mode       : ${HACTIVE}x${VACTIVE} @ ${CLOCK_KHZ} kHz, ${DSI_LANES} DSI lane(s)"
say "  touch      : ${TOUCH_ADDR:-none}"

# ------------------------------------------------------------ preflight ----
step "Preflight"
is_uno_q || warn "this does not look like an UNO Q (model: $(tr -d '\0' < /proc/device-tree/model 2>/dev/null))"
have_cmd curl || die "curl is required"

say ""
warn "POWER: the carrier needs a 5V/3A supply. A PC USB port is not enough -"
warn "the panel's I2C writes fail intermittently and the display will not come up."

if ! kernel_has_carrier_overlays; then
    step "This board needs an OS update first"
    say "  No Media Carrier overlays found, so this is a pre-carrier image."
    say "  Running scripts/10-update-os.sh ..."
    say ""
    sh "$HERE/scripts/10-update-os.sh"
    say ""
    die "Reboot and run this installer again:  sudo reboot"
fi
ok "Media Carrier overlays present"

# -------------------------------------------------------------- install ----
sh "$HERE/scripts/20-build-drivers.sh"   "$PANEL_DEF"
sh "$HERE/scripts/25-install-dkms.sh"    "$PANEL_DEF"
sh "$HERE/scripts/30-install-overlay.sh" "$PANEL_DEF"
sh "$HERE/scripts/35-install-recovery.sh" "$PANEL_DEF"

step "Done"
say "Reboot, then verify:"
say ""
say "    sudo reboot"
say "    sudo ./scripts/40-verify.sh \"$PANEL_DEF\""
say "    sudo ./scripts/test-display.sh"
[ -n "$TOUCH_ADDR" ] && say "    sudo ./scripts/test-touch.sh"
say ""
say "To undo everything:  sudo ./uninstall.sh"

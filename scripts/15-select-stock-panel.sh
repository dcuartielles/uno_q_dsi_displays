#!/bin/sh
# Select a panel the kernel and Arduino's overlay already support.
#
#   sudo ./scripts/15-select-stock-panel.sh panels/arduino-5in-touch-a.panel
#
# For panels marked STOCK_SUPPORT=1 this is the WHOLE installation. It builds
# nothing, patches nothing and replaces no overlay - it checks the drivers are
# there and selects Arduino's own overlay.
#
# Why this exists as a separate path
# ----------------------------------
# install.sh's normal route generates an overlay from the .panel description
# and writes it into Arduino's 5-inch display slot. For the official
# 5inch-DSI-TOUCH-A that is not merely unnecessary, it is destructive: the
# generated overlay describes different hardware entirely - one DSI lane
# instead of four, an RPi attiny at 0x45 instead of a waveshare GPIO chip, an
# edt-ft5x06 touch at 0x38 instead of a Goodix at 0x5d - and the panel then
# comes up with no DRM connector at all.
#
# Observed on a real board: the slot held our Waveshare overlay, and the panel
# was dark with no connector, no mode and no backlight. Restoring Arduino's
# overlay brought it straight up at 720x1280 with Goodix touch working.
set -e
HERE=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
. "$HERE/lib/common.sh"
need_root "$@"

PANEL_DEF=${1:?usage: $0 <panel definition>}
[ -f "$PANEL_DEF" ] || die "no such panel definition: $PANEL_DEF"
PANEL_DEF=$(abspath "$PANEL_DEF")
load_panel "$PANEL_DEF"

[ "${STOCK_SUPPORT:-0}" = "1" ] || die \
    "$PANEL_ID is not a stock-supported panel - use install.sh instead"

have_cmd arduino-linux-config || die \
    "arduino-linux-config not found. Run scripts/10-update-os.sh first."

step "Selecting $PANEL_ID"
say "  Arduino ships the overlay for this panel and the kernel has every"
say "  driver it needs, so nothing is built, patched or replaced here."

# ------------------------------------------------------------- the drivers --
# Check before promising: on a kernel too old to know this panel, the overlay
# would load and nothing would bind, which looks exactly like a hardware fault.
step "Checking the kernel has the drivers"
K=$(uname -r)
missing=0
for pair in \
    "waveshare,5.0-dsi-touch-a:${STOCK_PANEL_DRIVER:-panel-himax-hx8394}" \
    "waveshare,dsi-touch-gpio:${STOCK_GPIO_DRIVER:-gpio-waveshare-dsi}" \
    "goodix,gt9271:${STOCK_TOUCH_DRIVER:-goodix_ts}"
do
    compat=${pair%%:*}
    drv=${pair##*:}
    if modinfo -n "$drv" >/dev/null 2>&1 || \
       grep -qi "C${compat}" "/lib/modules/$K/modules.alias" 2>/dev/null; then
        ok "$compat -> $drv"
    else
        warn "$compat -> $drv NOT FOUND"
        missing=$((missing + 1))
    fi
done
[ "$missing" -eq 0 ] || die \
    "this kernel does not have the drivers for $PANEL_ID.
    Run scripts/10-update-os.sh to get a kernel that does."

# --------------------------------------------------------- Arduino's overlay --
# If a previous install of a DESCRIBED panel overwrote the slot, put Arduino's
# own overlay back - otherwise this panel gets someone else's description and
# comes up dark.
step "Making sure Arduino's own overlay is in place"
if [ -f "$SLOT_BACKUP" ]; then
    if cmp -s "$SLOT_BACKUP" "$SLOT_DTBO"; then
        ok "already Arduino's original"
    else
        cp -a "$SLOT_DTBO" "$SLOT_DTBO.replaced-$(date +%Y%m%d%H%M%S)"
        cp -a "$SLOT_BACKUP" "$SLOT_DTBO"
        ok "restored Arduino's overlay (the previous one was kept alongside it)"
    fi
else
    ok "untouched by this repository"
fi

step "Enabling the carrier display"
arduino-linux-config carrier enable media-carrier "display=$CARRIER_DISPLAY_OPTION"
record_state "stock panel $PANEL_ID selected"

say ""
warn "This disables DisplayPort over USB-C. The SoC has ONE DSI controller and"
warn "the panel and the USB-C bridge cannot both use it."
say ""
say "${C_BLD}Reboot to apply${C_OFF}, then check with:"
say "    sudo ./scripts/40-verify.sh \"$PANEL_DEF\""
say ""
say "    sudo reboot"

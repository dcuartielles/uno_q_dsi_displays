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
# Taken from the panel definition rather than hardcoded: the stock panels do
# NOT share a panel driver. The 5 inch is a Himax hx8394, the 10.1 inch a
# Jadard jd9365da, and checking for the wrong one would either refuse to
# install a panel that works or promise one that does not.
# A driver can be here in three different ways, and only checking for one of
# them refused to install the 10.1 inch panel on a board that was ALREADY
# running it: jadard-jd9365da is built into the kernel, so modinfo cannot see
# it, and this kernel does not list it in modules.builtin either. It is visible
# in sysfs, because a built-in driver registers at boot whether or not the
# hardware is present.
have_driver() {
    modinfo -n "$1" >/dev/null 2>&1 && { echo module; return 0; }
    grep -q "/$1\.ko" "/lib/modules/$(uname -r)/modules.builtin" 2>/dev/null         && { echo built-in; return 0; }
    for _d in /sys/bus/*/drivers/"$1"; do
        [ -d "$_d" ] && { echo registered; return 0; }
    done
    return 1
}

missing=0
for drv in ${STOCK_DRIVERS:-${STOCK_PANEL_DRIVER:-panel-himax-hx8394} ${STOCK_GPIO_DRIVER:-gpio-waveshare-dsi} ${STOCK_TOUCH_DRIVER:-goodix_ts}}; do
    if how=$(have_driver "$drv"); then
        ok "$drv ($how)"
    else
        warn "$drv NOT FOUND"
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
# This panel's own slot, not the 5 inch one. Only described panels hijack the
# 5 inch slot, so for anything else there is usually nothing to put back - but
# saying which slot was checked is worth the line.
PANEL_SLOT=$(slot_dtbo_for "$CARRIER_DISPLAY_OPTION") \
    || die "no overlay slot known for display option $CARRIER_DISPLAY_OPTION"
PANEL_SLOT_BACKUP="$PANEL_SLOT.arduino-orig"

if [ ! -f "$PANEL_SLOT" ]; then
    die "this OS has no overlay for $CARRIER_DISPLAY_OPTION.
    Run scripts/10-update-os.sh to get an image that ships it."
fi

if [ -f "$PANEL_SLOT_BACKUP" ]; then
    if cmp -s "$PANEL_SLOT_BACKUP" "$PANEL_SLOT"; then
        ok "already Arduino's original"
    else
        cp -a "$PANEL_SLOT" "$PANEL_SLOT.replaced-$(date +%Y%m%d%H%M%S)"
        cp -a "$PANEL_SLOT_BACKUP" "$PANEL_SLOT"
        ok "restored Arduino's overlay (the previous one was kept alongside it)"
    fi
else
    ok "$(basename "$PANEL_SLOT") is untouched by this repository"
fi

# The Goodix touch controller needs a patched driver on this hardware: the CCI
# bus refuses reads over 12 bytes and goodix.c asks for 32 at a time, so touch
# binds, creates an input device and reports nothing. Not optional, and not
# visible without actually touching the screen.
case "${TOUCH_ADDR:-}" in
    0x5d|0x5D)
        sh "$HERE/scripts/17-install-goodix-fix.sh" "$PANEL_DEF"
        ;;
esac

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

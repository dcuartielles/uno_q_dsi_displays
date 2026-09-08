#!/bin/sh
# Install a panel that needs a driver from outside this kernel and an overlay
# derived from one Arduino already ships.
#
#   sudo ./scripts/16-install-derived-panel.sh panels/arduino-12in-touch-a.panel
#
# A third kind of panel
# ---------------------
# There were two before this: panels the kernel already knows (selected, with
# scripts/15-select-stock-panel.sh) and panels described from scratch in a
# .panel file (built, with 20/30). The 12.3 inch is neither.
#
# It cannot be selected, because Arduino ships no overlay for it and the kernel
# has no mode for it. It cannot be described either: the generator in this
# repository emits Raspberry Pi style hardware - an ATTINY at 0x45, an
# edt-ft5x06 at 0x38 - and this panel has a waveshare GPIO chip and a Goodix.
#
# What it does have is a driver upstream. Raspberry Pi's tree carries the mode,
# the DSI parameters and the vendor initialisation sequence, and that driver
# compiles against the Arduino kernel unmodified. So the panel needs no new
# driver written - only that one trimmed to it, and an overlay that hands it
# the hardware the way it expects.
#
# Where the timings live, and why this is not a .panel file
# --------------------------------------------------------
# Arduino's overlays carry no timings at all. The panel node is a compatible
# string and nothing more; the modes are inside the kernel driver, keyed on
# that string. That is why the 8 inch and 10.1 inch overlays differ only in one
# string, and why putting the wrong one on gives a garbled picture with a clean
# dmesg. A new panel therefore means new driver data, not new device tree.
set -e
HERE=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
. "$HERE/lib/common.sh"
need_root "$@"

PANEL_DEF=${1:?usage: $0 <panel definition>}
[ -f "$PANEL_DEF" ] || die "no such panel definition: $PANEL_DEF"
PANEL_DEF=$(abspath "$PANEL_DEF")
load_panel "$PANEL_DEF"

[ "${DERIVED_PANEL:-0}" = "1" ] || die \
    "$PANEL_ID is not a derived panel - use install.sh"

for v in PANEL_DT_COMPATIBLE OVERLAY_TEMPLATE_OPTION CARRIER_DISPLAY_OPTION \
         DRIVER_URL DRIVER_PATCHER; do
    eval "val=\$$v"
    [ -n "$val" ] || die "$PANEL_DEF: missing required field $v"
done

K=$(uname -r)
MODDIR=/lib/modules/$K
[ -d "$MODDIR/build" ] || die "no kernel headers for $K"
have_cmd dtc || die "dtc is not installed: apt-get install device-tree-compiler"

BUILD=${BUILD_DIR:-$HOME/.uno-q-dsi-build}/derived
mkdir -p "$BUILD"

# ------------------------------------------------------------- the driver ---
step "Fetching the panel driver"
DRV_SRC=$(basename "$DRIVER_URL")
if [ ! -s "$BUILD/$DRV_SRC.pristine" ]; then
    curl -fsSL --max-time 120 "$DRIVER_URL" -o "$BUILD/$DRV_SRC.pristine" \
        || die "could not fetch $DRIVER_URL"
fi
cp "$BUILD/$DRV_SRC.pristine" "$BUILD/$DRV_SRC"
ok "$DRV_SRC"

step "Trimming it to this panel"
# Not cosmetic. The upstream driver matches seventeen compatible strings and
# three of them are panels this board already supports with built-in drivers.
# A module claiming those could bind first and hand a working panel another
# panel's initialisation sequence.
python3 "$HERE/$DRIVER_PATCHER" "$BUILD/$DRV_SRC"

step "Building"
DRV_OBJ=${DRV_SRC%.c}
printf 'obj-m += %s.o\n' "$DRV_OBJ" > "$BUILD/Makefile"
make -C "$MODDIR/build" M="$BUILD" modules >/dev/null 2>"$BUILD/build.log" || {
    tail -30 "$BUILD/build.log"
    die "module build failed (see $BUILD/build.log)"
}
install -D -m 644 "$BUILD/$DRV_OBJ.ko" "$MODDIR/updates/$DRV_OBJ.ko"
depmod -a
ok "$DRV_OBJ installed"

# ------------------------------------------------------------ the overlay ---
step "Building the overlay from Arduino's $OVERLAY_TEMPLATE_OPTION"
TEMPLATE=$(slot_dtbo_for "$OVERLAY_TEMPLATE_OPTION") \
    || die "no overlay slot known for $OVERLAY_TEMPLATE_OPTION"
[ -f "$TEMPLATE" ] || die "this OS does not ship $OVERLAY_TEMPLATE_OPTION"

SLOT=$(slot_dtbo_for "$CARRIER_DISPLAY_OPTION") \
    || die "no overlay slot known for $CARRIER_DISPLAY_OPTION"

dtc -I dtb -O dts "$TEMPLATE" -o "$BUILD/panel.dts" 2>/dev/null

PANEL_DT_COMPATIBLE="$PANEL_DT_COMPATIBLE" \
RESET_GPIO_LINE="${RESET_GPIO_LINE:-1}" \
IOVCC_GPIO_LINE="${IOVCC_GPIO_LINE:-4}" \
AVDD_GPIO_LINE="${AVDD_GPIO_LINE:-0}" \
TOUCH_SWAP_XY="${TOUCH_SWAP_XY:-0}" \
TOUCH_INVERT_X="${TOUCH_INVERT_X:-0}" \
TOUCH_INVERT_Y="${TOUCH_INVERT_Y:-0}" \
python3 "$HERE/tools/derive-overlay.py" "$BUILD/panel.dts"

dtc -I dts -O dtb "$BUILD/panel.dts" -o "$BUILD/panel.dtbo" 2>"$BUILD/dtc.log" || {
    tail -10 "$BUILD/dtc.log"; die "overlay compile failed"
}
ok "overlay built"

step "Installing into the $CARRIER_DISPLAY_OPTION slot"
# arduino-linux-config hardcodes its option names and .dtbo filenames inside a
# Go binary, so a new display option cannot be registered. Reusing a slot is
# the only way in; the original is preserved.
[ -f "$SLOT.arduino-orig" ] || cp -a "$SLOT" "$SLOT.arduino-orig"
cp -a "$BUILD/panel.dtbo" "$SLOT"
ok "$(basename "$SLOT") (original kept as .arduino-orig)"

# The overlay is merged into the base dtb OFFLINE, when the option is enabled -
# there is no CONFIG_OF_OVERLAY here. Replacing the .dtbo alone changes
# nothing, and the symptom is silent: the old merged blob keeps loading.
step "Enabling the carrier display"
arduino-linux-config carrier enable media-carrier "display=$CARRIER_DISPLAY_OPTION"
record_state "derived panel $PANEL_ID installed"

# The Goodix on this carrier needs its reads split; see 17 for why.
case "${TOUCH_ADDR:-}" in
    0x5d|0x5D) sh "$HERE/scripts/17-install-goodix-fix.sh" "$PANEL_DEF" ;;
esac

say ""
warn "This disables DisplayPort over USB-C - the SoC has one DSI controller."
say ""
say "${C_BLD}Reboot to apply${C_OFF}, then look at the screen and touch it:"
say ""
say "    sudo reboot"
say "    sudo ./scripts/45-confirm-display.sh \"$PANEL_DEF\""

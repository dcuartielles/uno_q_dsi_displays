#!/bin/sh
# Generate, compile and install the device-tree overlay, then enable it.
#
#   sudo ./scripts/30-install-overlay.sh panels/<your-panel>.panel
set -e
HERE=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
. "$HERE/lib/common.sh"
need_root "$@"

PANEL_DEF=${1:?usage: $0 <panel definition>}
[ -f "$PANEL_DEF" ] || die "no such panel definition: $PANEL_DEF"
PANEL_DEF=$(abspath "$PANEL_DEF")
load_panel "$PANEL_DEF"
kernel_has_carrier_overlays || die "Media Carrier overlays missing. Run scripts/10-update-os.sh first."
have_cmd arduino-linux-config || die "arduino-linux-config not found. Run scripts/10-update-os.sh first."

mkdir -p "$BUILD_DIR"
DTS="$BUILD_DIR/$PANEL_ID.dts"
DTBO="$BUILD_DIR/$PANEL_ID.dtbo"

step "Generating the overlay for $PANEL_ID"
python3 "$HERE/tools/gen-overlay.py" "$PANEL_DEF" "$DTS"

step "Compiling"
dtc -@ -I dts -O dtb -o "$DTBO" "$DTS" 2>&1 | grep -v '^$' || true
[ -s "$DTBO" ] || die "dtc failed to produce $DTBO"
ok "$DTBO"

step "Test-composing against the base device tree"
fdtoverlay -i "$BASE_DTB" -o "$BUILD_DIR/test.dtb" "$CARRIER_DTBO" "$DTBO" \
    || die "fdtoverlay failed - the overlay does not apply to this base DTB"
ok "composes cleanly"

step "Installing into Arduino's 5-inch display slot"
say "  arduino-linux-config hardcodes its display option names and .dtbo"
say "  filenames internally, so a new option cannot be registered. We put our"
say "  overlay in the 5-inch slot and select it as '$CARRIER_DISPLAY_OPTION'."
say ""
if [ ! -f "$SLOT_BACKUP" ]; then
    cp -a "$SLOT_DTBO" "$SLOT_BACKUP"
    ok "Arduino's original saved as $(basename "$SLOT_BACKUP")"
else
    ok "Arduino's original already backed up"
fi
cp "$DTBO" "$SLOT_DTBO"
record_state "overlay $PANEL_ID installed in the 5-inch slot"

step "Enabling the carrier display"
arduino-linux-config carrier enable media-carrier "display=$CARRIER_DISPLAY_OPTION"
say ""
warn "This disables DisplayPort over USB-C. The SoC has ONE DSI controller and"
warn "the panel and the USB-C bridge cannot both use it."
say ""
say "${C_BLD}Reboot to apply${C_OFF}, then check with:"
say "    sudo ./scripts/40-verify.sh \"$PANEL_DEF\""
say ""
say "    sudo reboot"

#!/bin/sh
# Runs ON the UNO Q. Stdin secrets contract: 1. sudo password  2. SSID  3. wifi pw
#
# Switch to the Waveshare 8-DSI-TOUCH-A - the display Arduino officially supports.
#
# Also restores Arduino's original 5-inch overlay into its slot, so nothing is
# left booby-trapped for a future 5-DSI-TOUCH-A. Our custom 800x480 overlay is
# kept as .ours alongside it.
#
# Drivers for this panel are all in-tree, nothing to build:
#   gpio-waveshare-dsi.ko        - controller @0x45 (gpio + backlight)
#   panel-jadard-jd9365da-h3.ko  - claims "waveshare,8.0-dsi-touch-a"
#   goodix_ts.ko                 - GT9271 touch @0x5d
unset HISTFILE
IFS= read -r SUDO_PASS; SUDO_PASS=$(printf '%s' "$SUDO_PASS" | tr -d '\r')
IFS= read -r WIFI_SSID
IFS= read -r WIFI_PASS
S() { printf '%s\n' "$SUDO_PASS" | sudo -S -p '' "$@"; }
S true 2>/dev/null || { echo "SUDO PASSWORD REJECTED"; exit 1; }

D=/boot/efi/dtb/qcom
SLOT5=$D/qrb2210-arduino-imola-carrier-media-panel-5in_touch_a-dsi.dtbo

echo "=== restore Arduino's original 5-inch overlay (housekeeping) ==="
if [ -f "$SLOT5.orig" ]; then
    S cp "$SLOT5.orig" "$SLOT5"
    echo "  5-inch slot restored to Arduino's original"
    echo "  (our 800x480 overlay preserved at $SLOT5.ours)"
else
    echo "  no .orig backup - leaving as is"
fi

echo
echo "=== confirm the 8-inch overlay is pristine (we never touched it) ==="
ls -la $D/qrb2210-arduino-imola-carrier-media-panel-8in_touch_a-dsi.dtbo

echo
echo "=== drivers this panel needs (all in-tree) ==="
K=$(uname -r)
for m in gpio-waveshare-dsi panel-jadard-jd9365da-h3 goodix_ts; do
    f=$(find /lib/modules/$K -name "$m.ko*" 2>/dev/null | head -1)
    printf '  %-30s %s\n' "$m" "${f:-MISSING}"
done
echo "  compatible claimed:"
grep -o 'waveshare,8.0-dsi-touch-a' /lib/modules/$K/modules.alias | head -1

echo
echo "=== select the 8-inch display ==="
S arduino-linux-config carrier enable media-carrier display=8-dsi-touch-a 2>&1

echo
echo "=== current config ==="
arduino-linux-config carrier show 2>&1 | head -6

echo
echo "============================================================"
echo " NOW: power the board OFF, swap in the 8-DSI-TOUCH-A panel,"
echo " then power it back on. The 8-inch panel uses a plain 22-pin"
echo " cable - no 15-to-22 adapter."
echo " (Datasheet: power off before touching the carrier connectors.)"
echo "============================================================"

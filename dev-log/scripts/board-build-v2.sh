#!/bin/sh
# Runs ON the UNO Q. Stdin secrets contract: 1. sudo password  2. SSID  3. wifi pw
#
# Compile the v2 (RPi-faithful) 5-inch overlay and stage it in the 5-inch slot.
# Does NOT touch the running 8-inch configuration - that uses the 8in dtbo.
unset HISTFILE
IFS= read -r SUDO_PASS; SUDO_PASS=$(printf '%s' "$SUDO_PASS" | tr -d '\r')
IFS= read -r WIFI_SSID
IFS= read -r WIFI_PASS
S() { printf '%s\n' "$SUDO_PASS" | sudo -S -p '' "$@"; }
S true 2>/dev/null || { echo "SUDO PASSWORD REJECTED"; exit 1; }

D=/boot/efi/dtb/qcom
SRC=$HOME/panel-build/uno-q-waveshare-5in-800x480-rpi-v2.dts
OUT=$HOME/panel-build/uno-q-waveshare-5in-800x480-rpi-v2.dtbo
SLOT=$D/qrb2210-arduino-imola-carrier-media-panel-5in_touch_a-dsi.dtbo

echo "=== compile ==="
dtc -@ -I dts -O dtb -o "$OUT" "$SRC" 2>&1
[ -s "$OUT" ] || { echo ">>> COMPILE FAILED"; exit 1; }
ls -la "$OUT"

echo
echo "=== fixups it expects from the base DTB ==="
dtc -I dtb -O dts "$OUT" 2>/dev/null | sed -n '/__fixups__/,/};/p'

echo
echo "=== DRY RUN compose: base + carrier-media + v2 ==="
rm -f /tmp/v2.dtb
if fdtoverlay -i "$D/qrb2210-arduino-imola-base.dtb" -o /tmp/v2.dtb \
      "$D/qrb2210-arduino-imola-carrier-media.dtbo" "$OUT" 2>&1; then
    echo "fdtoverlay: OK ($(stat -c%s /tmp/v2.dtb) bytes)"
else
    echo ">>> fdtoverlay FAILED"; exit 1
fi

echo
echo "=== verify the composed tree ==="
dtc -I dtb -O dts /tmp/v2.dtb 2>/dev/null > /tmp/v2.dts
echo "--- bridge (should have vddc-supply, NO reset-gpios) ---"
grep -n -A8 'toshiba,tc358762' /tmp/v2.dts | head -14
echo "--- bridge regulator ---"
grep -n -B2 -A6 'bridge_reg' /tmp/v2.dts | head -14
echo "--- panel timings ---"
grep -n -A16 'panel-timing' /tmp/v2.dts | head -20
echo "--- touch ---"
grep -n -A6 'edt,edt-ft5506' /tmp/v2.dts | head -10
echo "--- data-lanes ---"
grep -n 'data-lanes' /tmp/v2.dts

echo
echo "=== stage into the 5-inch slot (8-inch config untouched) ==="
S cp "$OUT" "$SLOT"
ls -la "$SLOT"*

echo
echo "=== current carrier config (should still be 8-dsi-touch-a) ==="
arduino-linux-config carrier show 2>&1 | head -6

echo
echo "============================================================"
echo " Ready. When the 5-inch panel is plugged back in:"
echo "   arduino-linux-config carrier enable media-carrier display=5-dsi-touch-a"
echo "   sudo reboot"
echo " To come back to the working 8-inch:"
echo "   arduino-linux-config carrier enable media-carrier display=8-dsi-touch-a"
echo "============================================================"

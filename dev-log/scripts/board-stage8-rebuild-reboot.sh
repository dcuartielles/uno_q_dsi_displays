#!/bin/sh
# Runs ON the UNO Q. Stdin secrets contract: 1. sudo password  2. SSID  3. wifi pw
# Stage 8: recompile the overlay after the reset-gpios + 1-lane fix, recompose, reboot.
unset HISTFILE

IFS= read -r SUDO_PASS; SUDO_PASS=$(printf '%s' "$SUDO_PASS" | tr -d '\r')
IFS= read -r WIFI_SSID
IFS= read -r WIFI_PASS

S() { printf '%s\n' "$SUDO_PASS" | sudo -S -p '' "$@"; }
S true 2>/dev/null || { echo "SUDO PASSWORD REJECTED"; exit 1; }

D=/boot/efi/dtb/qcom
SRC=$HOME/panel-build/uno-q-waveshare-5in-800x480-tc358762.dts
OUT=$HOME/panel-build/uno-q-waveshare-5in-800x480-tc358762.dtbo
SLOT=$D/qrb2210-arduino-imola-carrier-media-panel-5in_touch_a-dsi.dtbo

echo "=== recompile ==="
dtc -@ -I dts -O dtb -o "$OUT" "$SRC" 2>&1
[ -s "$OUT" ] || { echo ">>> COMPILE FAILED"; exit 1; }
ls -la "$OUT"

echo
echo "=== verify the two fixes made it into the blob ==="
dtc -I dtb -O dts "$OUT" 2>/dev/null > /tmp/ov.dts
echo "--- reset-gpios on the bridge ---"
grep -n -B2 -A1 "reset-gpios" /tmp/ov.dts
echo "--- data-lanes ---"
grep -n "data-lanes" /tmp/ov.dts
echo "--- fixups (attiny must now be a LOCAL phandle, not a fixup) ---"
sed -n '/__fixups__/,/};/p' /tmp/ov.dts

echo
echo "=== install into the 5-inch slot ==="
S cp "$OUT" "$SLOT"
ls -la "$SLOT"

echo
echo "=== recompose the live DTB ==="
S arduino-linux-config carrier enable media-carrier display=5-dsi-touch-a 2>&1
echo "--- bridge present in composed DTB? ---"
dtc -I dtb -O dts "$D/qrb2210-arduino-imola.dtb" 2>/dev/null | grep -c 'toshiba,tc358762'
echo "--- data-lanes in composed DTB ---"
dtc -I dtb -O dts "$D/qrb2210-arduino-imola.dtb" 2>/dev/null | grep 'data-lanes'

echo
echo "=== rebooting in 3s ==="
S nohup sh -c 'sleep 3; systemctl reboot' >/dev/null 2>&1 &
sleep 1
echo "reboot scheduled"

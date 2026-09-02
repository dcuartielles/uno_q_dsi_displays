#!/bin/sh
# Runs ON the UNO Q. Stdin secrets contract: 1. sudo password  2. SSID  3. wifi pw
# Compile and apply the v3 (ICN6211) overlay, then reboot.
unset HISTFILE
IFS= read -r SUDO_PASS; SUDO_PASS=$(printf '%s' "$SUDO_PASS" | tr -d '\r')
IFS= read -r WIFI_SSID
IFS= read -r WIFI_PASS
S() { printf '%s\n' "$SUDO_PASS" | sudo -S -p '' "$@"; }
S true 2>/dev/null || { echo "SUDO PASSWORD REJECTED"; exit 1; }

D=/boot/efi/dtb/qcom
SRC=$HOME/panel-build/uno-q-waveshare-5in-800x480-icn6211-v3.dts
OUT=$HOME/panel-build/uno-q-waveshare-5in-800x480-icn6211-v3.dtbo
SLOT=$D/qrb2210-arduino-imola-carrier-media-panel-5in_touch_a-dsi.dtbo

echo "=== make sure the ICN6211 module autoloads ==="
printf 'chipone-icn6211\nrpi-panel-attiny-regulator\n' > /tmp/pm.conf
S cp /tmp/pm.conf /etc/modules-load.d/panel-tc358762.conf
cat /etc/modules-load.d/panel-tc358762.conf

echo
echo "=== compile v3 ==="
dtc -@ -I dts -O dtb -o "$OUT" "$SRC" 2>&1
[ -s "$OUT" ] || { echo ">>> COMPILE FAILED"; exit 1; }
ls -la "$OUT"

echo
echo "=== dry-run compose ==="
rm -f /tmp/v3.dtb
fdtoverlay -i "$D/qrb2210-arduino-imola-base.dtb" -o /tmp/v3.dtb \
    "$D/qrb2210-arduino-imola-carrier-media.dtbo" "$OUT" 2>&1 \
    && echo "fdtoverlay OK" || { echo ">>> compose FAILED"; exit 1; }

echo
echo "=== verify the composed tree ==="
dtc -I dtb -O dts /tmp/v3.dtb 2>/dev/null > /tmp/v3.dts
grep -n -A4 'chipone,icn6211' /tmp/v3.dts | head -12
echo "--- data-lanes (expect two entries in both endpoints) ---"
grep -n 'data-lanes' /tmp/v3.dts
echo "--- enable-gpios ---"
grep -n 'enable-gpios' /tmp/v3.dts

echo
echo "=== install into the 5-inch slot (v2 kept as .v2) ==="
[ -f "$SLOT.v2" ] || S cp "$SLOT" "$SLOT.v2"
S cp "$OUT" "$SLOT"
ls -la "$SLOT"*

echo
echo "=== apply ==="
S arduino-linux-config carrier enable media-carrier display=5-dsi-touch-a 2>&1 | tail -2

echo
echo "=== rebooting in 3s ==="
S nohup sh -c 'sleep 3; systemctl reboot' >/dev/null 2>&1 &
sleep 1
echo "reboot scheduled"

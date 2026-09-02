#!/bin/sh
# Runs ON the UNO Q. Stdin secrets contract: 1. sudo password  2. SSID  3. wifi pw
# Select the 5-inch slot (which now holds the v2 RPi-faithful overlay) and reboot.
unset HISTFILE
IFS= read -r SUDO_PASS; SUDO_PASS=$(printf '%s' "$SUDO_PASS" | tr -d '\r')
IFS= read -r WIFI_SSID
IFS= read -r WIFI_PASS
S() { printf '%s\n' "$SUDO_PASS" | sudo -S -p '' "$@"; }
S true 2>/dev/null || { echo "SUDO PASSWORD REJECTED"; exit 1; }

D=/boot/efi/dtb/qcom
SLOT=$D/qrb2210-arduino-imola-carrier-media-panel-5in_touch_a-dsi.dtbo

echo "=== confirm the v2 overlay is in the slot ==="
ls -la "$SLOT"
echo "--- it should contain the RPi structure: bridge_reg + hfp 131 ---"
dtc -I dtb -O dts "$SLOT" 2>/dev/null | grep -E 'bridge_reg|hfront-porch|clock-frequency|tc358762|ft5506' | head

echo
echo "=== select the 5-inch slot ==="
S arduino-linux-config carrier enable media-carrier display=5-dsi-touch-a 2>&1

echo
echo "=== composed DTB sanity ==="
dtc -I dtb -O dts $D/qrb2210-arduino-imola.dtb 2>/dev/null | grep -cE 'toshiba,tc358762'
dtc -I dtb -O dts $D/qrb2210-arduino-imola.dtb 2>/dev/null | grep -E 'hfront-porch|data-lanes' | head

echo
echo "=== rebooting in 3s ==="
S nohup sh -c 'sleep 3; systemctl reboot' >/dev/null 2>&1 &
sleep 1
echo "reboot scheduled"

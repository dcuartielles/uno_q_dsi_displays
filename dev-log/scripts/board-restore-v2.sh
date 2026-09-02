#!/bin/sh
# Runs ON the UNO Q. Stdin secrets contract: 1. sudo password  2. SSID  3. wifi pw
# Put our v2 (RPi-faithful) overlay back in the 5-inch slot after testing
# Arduino's official 5-dsi-touch-a configuration.
unset HISTFILE
IFS= read -r SUDO_PASS; SUDO_PASS=$(printf '%s' "$SUDO_PASS" | tr -d '\r')
IFS= read -r WIFI_SSID
IFS= read -r WIFI_PASS
S() { printf '%s\n' "$SUDO_PASS" | sudo -S -p '' "$@"; }
S true 2>/dev/null || { echo "SUDO PASSWORD REJECTED"; exit 1; }

D=/boot/efi/dtb/qcom
SLOT=$D/qrb2210-arduino-imola-carrier-media-panel-5in_touch_a-dsi.dtbo

[ -f "$SLOT.v2" ] || { echo "ERROR: $SLOT.v2 missing"; exit 1; }
S cp "$SLOT.v2" "$SLOT"
echo "restored our v2 overlay"
dtc -I dtb -O dts "$SLOT" 2>/dev/null | grep -E 'tc358762|bridge_reg|hfront-porch|ft5506' | sed 's/^/  /'

S arduino-linux-config carrier enable media-carrier display=5-dsi-touch-a 2>&1 | tail -2

echo
echo "=== rebooting in 3s ==="
S nohup sh -c 'sleep 3; systemctl reboot' >/dev/null 2>&1 &
sleep 1
echo "reboot scheduled"

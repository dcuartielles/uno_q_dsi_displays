#!/bin/sh
# Runs ON the UNO Q. Stdin secrets contract: 1. sudo password  2. SSID  3. wifi pw
# Stage 7: enable our custom panel overlay (installed into the 5in slot) and reboot.
unset HISTFILE

IFS= read -r SUDO_PASS; SUDO_PASS=$(printf '%s' "$SUDO_PASS" | tr -d '\r')
IFS= read -r WIFI_SSID
IFS= read -r WIFI_PASS

S() { printf '%s\n' "$SUDO_PASS" | sudo -S -p '' "$@"; }
S true 2>/dev/null || { echo "SUDO PASSWORD REJECTED"; exit 1; }

echo "=== enabling media-carrier with our overlay in the 5-inch slot ==="
S arduino-linux-config carrier enable media-carrier display=5-dsi-touch-a 2>&1

echo
echo "=== composed DTB ==="
ls -la /boot/efi/dtb/qcom/qrb2210-arduino-imola.dtb
echo "--- does the live composed DTB contain our bridge? ---"
dtc -I dtb -O dts /boot/efi/dtb/qcom/qrb2210-arduino-imola.dtb 2>/dev/null | grep -c 'toshiba,tc358762'

echo
echo "=== make sure the modules load at boot ==="
printf 'tc358762\nrpi-panel-attiny-regulator\n' > /tmp/panel-modules.conf
S cp /tmp/panel-modules.conf /etc/modules-load.d/panel-tc358762.conf
cat /etc/modules-load.d/panel-tc358762.conf

echo
echo "=== rebooting in 3s ==="
S nohup sh -c 'sleep 3; systemctl reboot' >/dev/null 2>&1 &
sleep 1
echo "reboot scheduled"

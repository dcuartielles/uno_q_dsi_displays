#!/bin/sh
# Runs ON the UNO Q. Stdin secrets contract: 1. sudo password  2. SSID  3. wifi pw
#
# Enables the media carrier with the official 5-inch DSI panel overlay.
# Fully reversible:  arduino-linux-config carrier disable media-carrier
#
# NOTE: this re-points the SoC's only DSI controller away from the ANX7625
# bridge, so DisplayPort-over-USB-C stops working while it is enabled. ADB is
# unaffected and remains our connection.
unset HISTFILE

IFS= read -r SUDO_PASS; SUDO_PASS=$(printf '%s' "$SUDO_PASS" | tr -d '\r')
IFS= read -r WIFI_SSID
IFS= read -r WIFI_PASS

S() { printf '%s\n' "$SUDO_PASS" | sudo -S -p '' "$@"; }
S true 2>/dev/null || { echo "SUDO PASSWORD REJECTED - stopping"; exit 1; }

echo "=== BEFORE ==="
arduino-linux-config carrier show 2>&1
ls -la /boot/efi/dtb/qcom/qrb2210-arduino-imola.dtb
ls /boot/efi/loader/entries/

echo
echo "=== enabling media-carrier with display=5-dsi-touch-a ==="
S arduino-linux-config carrier enable media-carrier display=5-dsi-touch-a 2>&1

echo
echo "=== AFTER (config) ==="
arduino-linux-config carrier show 2>&1

echo
echo "=== what changed on the ESP ==="
ls -la /boot/efi/dtb/qcom/qrb2210-arduino-imola.dtb
ls -la /boot/efi/loader/entries/
echo "--- devicetree line in the loader entry, if any ---"
grep -H devicetree /boot/efi/loader/entries/*.conf 2>/dev/null || echo "(no devicetree line)"

echo
echo "=== rebooting in 3s ==="
S nohup sh -c 'sleep 3; systemctl reboot' >/dev/null 2>&1 &
sleep 1
echo "reboot scheduled"

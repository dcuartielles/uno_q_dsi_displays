#!/bin/sh
# Runs ON the UNO Q. Stdin secrets contract: 1. sudo password  2. SSID  3. wifi pw
#
# Put our own overlay back in the 5-inch slot. It is the better of the two
# states: DRM comes up fully with the panel's correct 800x480 timings and a
# working framebuffer, whereas Arduino's touch-a overlay leaves no DRM device
# at all (its panel regulators never probe on this hardware).
unset HISTFILE
IFS= read -r SUDO_PASS; SUDO_PASS=$(printf '%s' "$SUDO_PASS" | tr -d '\r')
IFS= read -r WIFI_SSID
IFS= read -r WIFI_PASS
S() { printf '%s\n' "$SUDO_PASS" | sudo -S -p '' "$@"; }
S true 2>/dev/null || { echo "SUDO PASSWORD REJECTED"; exit 1; }

D=/boot/efi/dtb/qcom
SLOT=$D/qrb2210-arduino-imola-carrier-media-panel-5in_touch_a-dsi.dtbo

[ -f "$SLOT.ours" ] || { echo "ERROR: $SLOT.ours missing"; exit 1; }
S cp "$SLOT.ours" "$SLOT"
echo "restored our overlay into the slot"
ls -la "$SLOT" "$SLOT.orig" "$SLOT.ours"

S arduino-linux-config carrier enable media-carrier display=5-dsi-touch-a 2>&1

echo
echo "=== rebooting in 3s ==="
S nohup sh -c 'sleep 3; systemctl reboot' >/dev/null 2>&1 &
sleep 1
echo "reboot scheduled"

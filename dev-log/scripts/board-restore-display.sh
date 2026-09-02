#!/bin/sh
# Runs ON the UNO Q. Stdin secrets contract: 1. sudo password  2. SSID  3. wifi pw
#
# Reverts the 5-dsi-touch-a experiment. The overlay is wrong for our panel:
# it expects a Waveshare touch-a controller at 0x45, our panel has an
# RPi-7"-clone ATTINY there, so waveshare-regulator times out, the panel
# regulators never come up, and the whole DRM device fails to bind.
#
# Setting display=none restores the ANX7625 / USB-C DisplayPort path while
# keeping the carrier itself enabled.
unset HISTFILE

IFS= read -r SUDO_PASS; SUDO_PASS=$(printf '%s' "$SUDO_PASS" | tr -d '\r')
IFS= read -r WIFI_SSID
IFS= read -r WIFI_PASS

S() { printf '%s\n' "$SUDO_PASS" | sudo -S -p '' "$@"; }
S true 2>/dev/null || { echo "SUDO PASSWORD REJECTED"; exit 1; }

echo "=== before ==="
arduino-linux-config carrier show 2>&1 | head -6

echo
echo "=== setting display=none (keeping the carrier enabled) ==="
S arduino-linux-config carrier enable media-carrier display=none 2>&1

echo
echo "=== after ==="
arduino-linux-config carrier show 2>&1 | head -6

echo
echo "=== rebooting in 3s ==="
S nohup sh -c 'sleep 3; systemctl reboot' >/dev/null 2>&1 &
sleep 1
echo "reboot scheduled"

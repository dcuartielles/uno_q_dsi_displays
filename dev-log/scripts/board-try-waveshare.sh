#!/bin/sh
# Runs ON the UNO Q. Stdin secrets contract: 1. sudo password  2. SSID  3. wifi pw
#
# Restore Arduino's ORIGINAL 5in_touch_a overlay and retry it on good power.
#
# Rationale: the device at 0x45 ignores the Raspberry Pi ATTINY register map
# entirely (full dump unchanged after driver writes). Arduino's overlay binds
# "waveshare,dsi-touch-gpio" at that same address instead, driven by
# gpio-waveshare-dsi.ko. That was tried once and failed with -ETIMEDOUT, but
# only while the board was on a starved PC USB port - an invalid test.
#
# The panel timings will be wrong (that overlay is 720x1280 Himax, ours is
# 800x480 TC358762), so we do NOT expect a correct picture. We are only asking:
# does waveshare-regulator PROBE, and does the BACKLIGHT come on?
unset HISTFILE
IFS= read -r SUDO_PASS; SUDO_PASS=$(printf '%s' "$SUDO_PASS" | tr -d '\r')
IFS= read -r WIFI_SSID
IFS= read -r WIFI_PASS
S() { printf '%s\n' "$SUDO_PASS" | sudo -S -p '' "$@"; }
S true 2>/dev/null || { echo "SUDO PASSWORD REJECTED"; exit 1; }

D=/boot/efi/dtb/qcom
SLOT=$D/qrb2210-arduino-imola-carrier-media-panel-5in_touch_a-dsi.dtbo

echo "=== keep a copy of OUR overlay, restore Arduino's original ==="
S cp "$SLOT" "$SLOT.ours" 2>&1
if [ -f "$SLOT.orig" ]; then
    S cp "$SLOT.orig" "$SLOT"
    echo "restored Arduino's original into the slot"
else
    echo "ERROR: no .orig backup found"; exit 1
fi
ls -la "$SLOT" "$SLOT.orig" "$SLOT.ours"

echo
echo "=== recompose ==="
S arduino-linux-config carrier enable media-carrier display=5-dsi-touch-a 2>&1

echo
echo "=== rebooting in 3s ==="
S nohup sh -c 'sleep 3; systemctl reboot' >/dev/null 2>&1 &
sleep 1
echo "reboot scheduled"

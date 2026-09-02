#!/bin/sh
# Runs ON the UNO Q. Stdin secrets contract: 1. sudo password  2. SSID  3. wifi pw
# Scans every I2C bus as root, to see what is physically attached to the
# media carrier's DSI connector.
#
# Expected addresses for the two candidate panels:
#   5-DSI-TOUCH-A (720x1280)  -> 0x45 waveshare gpio, 0x5d GT9271 touch, 0x26 pca9555
#   5inch DSI LCD (800x480)   -> 0x45 ATTINY (RPi-7"-clone), 0x5d/0x14 GT911 touch
#   nothing connected         -> only the carrier's own devices (pca9555 @0x26)
unset HISTFILE

IFS= read -r SUDO_PASS; SUDO_PASS=$(printf '%s' "$SUDO_PASS" | tr -d '\r')
IFS= read -r WIFI_SSID
IFS= read -r WIFI_PASS

S() { printf '%s\n' "$SUDO_PASS" | sudo -S -p '' "$@"; }
S true 2>/dev/null || { echo "SUDO PASSWORD REJECTED"; exit 1; }

for b in /dev/i2c-0 /dev/i2c-1 /dev/i2c-2 /dev/i2c-3; do
    n=${b#/dev/i2c-}
    echo "===== i2c bus $n ====="
    S i2cdetect -y -r "$n" 2>&1
    echo
done

echo "===== which bus is which (device tree names) ====="
for d in /sys/bus/i2c/devices/i2c-*; do
    echo "$(basename "$d"): $(cat "$d/name" 2>/dev/null)"
done

echo
echo "===== bound i2c client devices ====="
ls -l /sys/bus/i2c/devices/ | grep -v "^total"

echo
echo "===== drm state ====="
ls /sys/class/drm/ 2>/dev/null
echo "(no card0 means the display subsystem never bound)"

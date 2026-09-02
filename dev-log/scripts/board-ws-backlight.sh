#!/bin/sh
# Runs ON the UNO Q. Stdin secrets contract: 1. sudo password  2. SSID  3. wifi pw
#
# What protocol does WAVESHARE use to control this panel's backlight?
# If it differs from the Raspberry Pi ATTINY register map, we have the wrong
# driver bound at 0x45 and that alone explains a dark backlight.
unset HISTFILE
IFS= read -r SUDO_PASS; IFS= read -r WIFI_SSID; IFS= read -r WIFI_PASS
cd /tmp || exit 1

echo "=== 'Adjust Backlight Brightness Using Terminal' section ==="
grep -n -A25 "Adjust Backlight Brightness Using Terminal" ws.txt | head -40

echo
echo "=== any i2c / i2cset / address / register mentions ==="
grep -n -i -B3 -A6 "i2cset\|i2cget\|0x45\|i2c-\|/dev/i2c\|address" ws.txt | head -50

echo
echo "=== backlight application / brightness commands ==="
grep -n -i -B3 -A10 "brightness\|backlight" ws.txt | head -80

echo
echo "=== driver / overlay names used ==="
grep -n -i "dtoverlay\|vc4-kms" ws.txt | head -20

echo
echo "=== Features list (full) ==="
sed -n '/^ *Features *$/,/Video Tutorial/p' ws.txt | head -30

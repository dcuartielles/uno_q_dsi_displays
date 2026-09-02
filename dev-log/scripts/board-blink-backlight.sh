#!/bin/sh
# Runs ON the UNO Q. Stdin secrets contract: 1. sudo password  2. SSID  3. wifi pw
#
# Decisive test. Drives the backlight through the DRIVER (sysfs), which uses the
# correct ver-2 ATTINY protocol, instead of raw i2c pokes.
#
# WATCH THE PANEL while this runs: it blinks the backlight 6 times over ~12s.
#   - if it visibly flickers -> ATTINY comms work, panel power is fine, and the
#     problem is purely that the TC358762 bridge is not emitting pixels
#   - if nothing at all       -> panel power / backlight path is dead
unset HISTFILE

IFS= read -r SUDO_PASS; SUDO_PASS=$(printf '%s' "$SUDO_PASS" | tr -d '\r')
IFS= read -r WIFI_SSID
IFS= read -r WIFI_PASS

S() { printf '%s\n' "$SUDO_PASS" | sudo -S -p '' "$@"; }
S true 2>/dev/null || { echo "SUDO PASSWORD REJECTED"; exit 1; }

BL=/sys/class/backlight/0-0045

echo "=== ver-2 handling in the driver ==="
grep -n -B4 -A22 "0xc3" "$HOME/panel-build/rpi-panel-attiny-regulator.c" | head -40

echo
echo "=== backlight device ==="
echo "max_brightness = $(cat $BL/max_brightness)"
echo "brightness     = $(cat $BL/brightness)"
echo "bl_power       = $(cat $BL/bl_power)"

echo
echo "*** WATCH THE PANEL - blinking backlight 6 times ***"
i=1
while [ "$i" -le 6 ]; do
    echo "  off"
    S sh -c "echo 0 > $BL/brightness"
    sleep 1
    echo "  on"
    S sh -c "echo 255 > $BL/brightness"
    sleep 1
    i=$((i + 1))
done

echo
echo "=== leaving backlight ON at full ==="
S sh -c "echo 255 > $BL/brightness"
cat $BL/brightness

echo
echo "=== repaint framebuffer white ==="
python3 -c "open('/dev/fb0','wb').write(bytes([255,255,255,255])*(800*480)); print('painted WHITE')"

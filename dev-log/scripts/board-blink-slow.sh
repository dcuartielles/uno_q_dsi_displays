#!/bin/sh
# Runs ON the UNO Q. Stdin secrets contract: 1. sudo password  2. SSID  3. wifi pw
#
# Slow, unmistakable backlight test - 5 cycles of 3s ON / 3s OFF (~30 seconds).
# Drives the backlight through the driver, and counts CCI i2c timeouts before
# and after so we can tell whether the writes are actually reaching the panel.
unset HISTFILE

IFS= read -r SUDO_PASS; SUDO_PASS=$(printf '%s' "$SUDO_PASS" | tr -d '\r')
IFS= read -r WIFI_SSID
IFS= read -r WIFI_PASS

S() { printf '%s\n' "$SUDO_PASS" | sudo -S -p '' "$@"; }
S true 2>/dev/null || { echo "SUDO PASSWORD REJECTED"; exit 1; }

BL=/sys/class/backlight/0-0045

BEFORE=$(S dmesg | grep -c "cci.*timeout")
echo "CCI i2c timeouts before test: $BEFORE"

# start from a known state: backlight off
S sh -c "echo 0 > $BL/brightness"

echo
echo "*** LOOK AT THE PANEL NOW - test starts in 5 seconds ***"
n=5
while [ "$n" -gt 0 ]; do printf '  %d...\n' "$n"; sleep 1; n=$((n - 1)); done
echo "    5 cycles of 4s ON / 4s OFF (~40 seconds)."
echo "    Even with no image, the backlight should make the panel visibly GLOW."
echo

i=1
while [ "$i" -le 5 ]; do
    printf '  cycle %d: ON  ... ' "$i"
    S sh -c "echo 255 > $BL/brightness" 2>&1 && echo "(write ok, brightness=$(cat $BL/brightness))"
    sleep 4
    printf '  cycle %d: OFF ... ' "$i"
    S sh -c "echo 0 > $BL/brightness" 2>&1 && echo "(write ok, brightness=$(cat $BL/brightness))"
    sleep 4
    i=$((i + 1))
done

S sh -c "echo 255 > $BL/brightness"
echo
AFTER=$(S dmesg | grep -c "cci.*timeout")
echo "CCI i2c timeouts after test:  $AFTER   (delta: $((AFTER - BEFORE)))"
echo "  delta 0  => the driver's I2C writes ARE reaching the panel controller"
echo "  delta >0 => writes are timing out on the bus"

echo
echo "=== repaint framebuffer: white/black vertical bars ==="
python3 -c "
w,h=800,480
row=b''.join((bytes([255,255,255,255]) if (x//40)%2==0 else bytes([0,0,0,255])) for x in range(w))
open('/dev/fb0','wb').write(row*h)
print('painted 40px vertical bars')
"
echo
echo "backlight left ON at $(cat $BL/brightness)"

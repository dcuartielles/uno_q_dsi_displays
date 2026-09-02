#!/bin/sh
# Runs ON the UNO Q. Stdin secrets contract: 1. sudo password  2. SSID  3. wifi pw
#
# Reads on this bus are proven trustworthy (the touch chip at 0x38 reads back
# sensible, varied firmware values). So if NOTHING in 0x45's register space ever
# changes in response to writes, the device is not honouring the Raspberry Pi
# ATTINY register map at all.
unset HISTFILE
IFS= read -r SUDO_PASS; SUDO_PASS=$(printf '%s' "$SUDO_PASS" | tr -d '\r')
IFS= read -r WIFI_SSID
IFS= read -r WIFI_PASS
S() { printf '%s\n' "$SUDO_PASS" | sudo -S -p '' "$@"; }
S true 2>/dev/null || { echo "SUDO PASSWORD REJECTED"; exit 1; }

B=$(basename "$(ls -d /sys/bus/i2c/devices/*-0045 2>/dev/null | head -1)" | cut -d- -f1)
BL=$(ls -d /sys/class/backlight/*/ 2>/dev/null | head -1)
echo "bus=$B  backlight=$BL"

echo
echo "=== full register dump of 0x45 (BEFORE) ==="
S i2cdump -f -y "$B" 0x45 b 2>&1 | head -20 | tee /tmp/dump_before.txt

echo
echo "=== drive the backlight through the driver: 255 -> 0 ==="
S sh -c "echo 0 > $BL/brightness"
sleep 1

echo "=== full register dump of 0x45 (AFTER brightness=0) ==="
S i2cdump -f -y "$B" 0x45 b 2>&1 | head -20 | tee /tmp/dump_after.txt

echo
echo "=== DIFF (any change at all?) ==="
if diff /tmp/dump_before.txt /tmp/dump_after.txt >/dev/null 2>&1; then
    echo ">>> IDENTICAL - not one byte changed. The device is ignoring the writes."
else
    echo ">>> CHANGED:"
    diff /tmp/dump_before.txt /tmp/dump_after.txt
fi

S sh -c "echo 255 > $BL/brightness"
sleep 1
echo
echo "=== dump AFTER brightness back to 255 ==="
S i2cdump -f -y "$B" 0x45 b 2>&1 | sed -n '2,10p'

echo
echo "=== does the TOUCH chip's report area change when you touch the panel? ==="
echo "*** TOUCH AND HOLD A FINGER ON THE SCREEN NOW - sampling for 10s ***"
i=1
while [ $i -le 10 ]; do
    printf '  t%02d: reg0x02(touches)=%s  x_hi=%s x_lo=%s\n' "$i" \
        "$(S i2cget -f -y "$B" 0x38 0x02 2>&1)" \
        "$(S i2cget -f -y "$B" 0x38 0x03 2>&1)" \
        "$(S i2cget -f -y "$B" 0x38 0x04 2>&1)"
    sleep 1
    i=$((i+1))
done

#!/bin/sh
# Runs ON the UNO Q. Stdin secrets contract: 1. sudo password  2. SSID  3. wifi pw
#
# The backlight is ON but at minimum brightness. So power and PC_LED_EN work,
# but the PWM value is not being applied. Sweep it two ways:
#   A) through the driver (sysfs)  - uses regmap, register REG_PWM 0x86
#   B) direct register writes      - in case the driver's path is wrong
# and also try REG_POWERON, in case this variant gates PWM behind it.
#
# WATCH THE PANEL and note which phase (if any) changes the brightness.
# The carrier's GREEN LEDs count the phase so it can be followed without
# seeing this terminal:  1 = sysfs sweep, 2 = direct 0x86 sweep, 3 = POWERON+PWM
unset HISTFILE
IFS= read -r SUDO_PASS; SUDO_PASS=$(printf '%s' "$SUDO_PASS" | tr -d '\r')
IFS= read -r WIFI_SSID
IFS= read -r WIFI_PASS
S() { printf '%s\n' "$SUDO_PASS" | sudo -S -p '' "$@"; }
S true 2>/dev/null || { echo "SUDO PASSWORD REJECTED"; exit 1; }

B=$(basename "$(ls -d /sys/bus/i2c/devices/*-0045 2>/dev/null | head -1)" | cut -d- -f1)
BL=$(ls -d /sys/class/backlight/*/ 2>/dev/null | head -1)
L=/sys/class/leds
echo "bus=$B  backlight=$BL"

leds_off(){ for n in 1 2 3 4; do S sh -c "echo 0 > $L/media-carrier:green$n/brightness" 2>/dev/null; done; }
leds_n(){ leds_off; i=1; while [ $i -le $1 ]; do S sh -c "echo 255 > $L/media-carrier:green$i/brightness" 2>/dev/null; i=$((i+1)); done; }

leds_off
echo
echo "*** WATCH THE PANEL BRIGHTNESS. Green LEDs count the phase. ***"
sleep 5

echo "--- PHASE 1 (1 LED): driver sysfs sweep 0 -> 64 -> 128 -> 192 -> 255 ---"
leds_n 1
for v in 0 64 128 192 255; do
    S sh -c "echo $v > $BL/brightness"
    echo "    sysfs brightness=$v (readback $(cat $BL/brightness))"
    sleep 3
done
leds_off; sleep 2

echo "--- PHASE 2 (2 LEDs): direct REG_PWM 0x86 sweep ---"
leds_n 2
for v in 0x00 0x40 0x80 0xc0 0xff; do
    S i2cset -f -y "$B" 0x45 0x86 $v 2>/dev/null
    echo "    0x86 <- $v"
    sleep 3
done
leds_off; sleep 2

echo "--- PHASE 3 (3 LEDs): REG_POWERON=1 then PWM=0xff ---"
leds_n 3
S i2cset -f -y "$B" 0x45 0x85 0x01 2>/dev/null; echo "    0x85 <- 0x01"
sleep 2
S i2cset -f -y "$B" 0x45 0x86 0xff 2>/dev/null; echo "    0x86 <- 0xff"
sleep 6
leds_off

echo
echo "=== leave it at maximum both ways ==="
S sh -c "echo 255 > $BL/brightness"
S i2cset -f -y "$B" 0x45 0x86 0xff 2>/dev/null
echo "  sysfs=$(cat $BL/brightness)"

echo
echo "=== repaint framebuffer: solid WHITE (easiest to see through a dim backlight) ==="
python3 -c "open('/dev/fb0','wb').write(bytes([255,255,255,255])*(800*480)); print('  painted WHITE')"

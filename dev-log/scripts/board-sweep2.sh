#!/bin/sh
# Runs ON the UNO Q. Stdin secrets contract: 1. sudo password  2. SSID  3. wifi pw
#
# Same power-on sweep as before, but the CARRIER'S GREEN LEDs count out the
# phase number so it can be followed without seeing the terminal:
#
#   1 green LED  = PHASE A : REG_POWERON=1 + PWM=255      (v1-firmware style)
#   2 green LEDs = PHASE B : PORTB/PORTA/PORTC + PWM=255  (v2 port style)
#   3 green LEDs = PHASE C : via the driver's backlight sysfs
#   4 green LEDs = PHASE D : bridge reset released by hand via the gpio chip
#
# All LEDs are off between phases, so each phase starts from darkness.
unset HISTFILE
IFS= read -r SUDO_PASS; SUDO_PASS=$(printf '%s' "$SUDO_PASS" | tr -d '\r')
IFS= read -r WIFI_SSID
IFS= read -r WIFI_PASS
S() { printf '%s\n' "$SUDO_PASS" | sudo -S -p '' "$@"; }
S true 2>/dev/null || { echo "SUDO PASSWORD REJECTED"; exit 1; }

L=/sys/class/leds
leds_off() { for n in 1 2 3 4; do S sh -c "echo 0 > $L/media-carrier:green$n/brightness" 2>/dev/null; done; }
leds_n()   { leds_off; i=1; while [ $i -le $1 ]; do S sh -c "echo 255 > $L/media-carrier:green$i/brightness" 2>/dev/null; i=$((i+1)); done; }

leds_off
echo "*** WATCH THE PANEL. The carrier's GREEN LEDs count the phase: 1, 2, 3, 4. ***"
echo "*** Note which count (if any) is showing when the panel lights.          ***"
sleep 5

echo "--- PHASE A : POWERON=1 + PWM=255  (1 LED) ---"
leds_n 1
S i2cset -f -y 0 0x45 0x85 0x01 2>/dev/null
sleep 1
S i2cset -f -y 0 0x45 0x86 0xff 2>/dev/null
sleep 10
leds_off; sleep 3

echo "--- PHASE B : PORTB/PORTA/PORTC + PWM=255  (2 LEDs) ---"
leds_n 2
S i2cset -f -y 0 0x45 0x82 0x80 2>/dev/null; sleep 1
S i2cset -f -y 0 0x45 0x81 0x04 2>/dev/null; sleep 1
S i2cset -f -y 0 0x45 0x83 0x0f 2>/dev/null; sleep 1
S i2cset -f -y 0 0x45 0x86 0xff 2>/dev/null
sleep 10
leds_off; sleep 3

echo "--- PHASE C : driver backlight sysfs 0 -> 255  (3 LEDs) ---"
leds_n 3
S sh -c "echo 0 > $L/../backlight/0-0045/brightness" 2>/dev/null
S sh -c 'echo 0 > /sys/class/backlight/0-0045/brightness'
sleep 2
S sh -c 'echo 255 > /sys/class/backlight/0-0045/brightness'
sleep 10
leds_off; sleep 3

echo "--- PHASE D : release bridge reset via gpio chip  (4 LEDs) ---"
leds_n 4
# gpiochip3 is the ATTINY: line 0 = RST_BRIDGE_N, line 1 = RST_TP_N.
# line 0 is normally held by tc358762; try anyway and report.
S gpioset --chip 3 0=1 1=1 2>&1 | head -3
S gpioset -c gpiochip3 0=1 1=1 2>&1 | head -3
S sh -c 'echo 255 > /sys/class/backlight/0-0045/brightness'
sleep 10
leds_off

echo
echo "=== repaint colour bars ==="
python3 -c "
W,H=800,480
bars=[(255,255,255),(0,255,255),(255,255,0),(0,255,0),(255,0,255),(0,0,255),(255,0,0),(0,0,0)]
row=b''
for x in range(W):
    b,g,r=bars[min(x*len(bars)//W,len(bars)-1)]
    row+=bytes([b,g,r,255])
open('/dev/fb0','wb').write(row*H)
print('bars painted')
"
S sh -c 'echo 255 > /sys/class/backlight/0-0045/brightness'
echo "backlight left at $(cat /sys/class/backlight/0-0045/brightness)"

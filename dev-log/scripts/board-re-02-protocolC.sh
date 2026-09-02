#!/bin/sh
# Runs ON the UNO Q. Stdin secrets contract: 1. sudo password  2. SSID  3. wifi pw
#
# REVERSE ENGINEERING, STEP 2: try Waveshare protocol "C".
#
# From RPi's panel-waveshare-dsi.c (their driver for the Waveshare DSI LCD
# series). All its registers are WRITE-ONLY, which fits our chip reading 0xff
# everywhere, and its backlight scale is INVERTED (0xff = dimmest), which fits
# a backlight stuck at minimum.
#
# Green LEDs count the phase:
#   1 = protocol C power-on sequence
#   2 = protocol C backlight sweep, dim -> bright  (0xab: 0xff -> 0x00)
#   3 = protocol B (touch-a) registers 0x94-0x96
#   4 = protocol C alternate enable value (0xad=0x02)
unset HISTFILE
IFS= read -r SUDO_PASS; SUDO_PASS=$(printf '%s' "$SUDO_PASS" | tr -d '\r')
IFS= read -r WIFI_SSID
IFS= read -r WIFI_PASS
S() { printf '%s\n' "$SUDO_PASS" | sudo -S -p '' "$@"; }
S true 2>/dev/null || { echo "SUDO PASSWORD REJECTED"; exit 1; }

cd "$HOME/re" 2>/dev/null || { echo "run board-re-01-recon.sh first"; exit 1; }

echo "############ protocol C: the exact sequences ############"
echo "--- prepare (power on) ---"
sed -n '/static int ws_panel_prepare/,/^}/p' panel-waveshare-dsi.c
echo "--- enable ---"
sed -n '/static int ws_panel_enable/,/^}/p' panel-waveshare-dsi.c
echo "--- backlight update ---"
sed -n '/static int ws_panel_bl_update_status/,/^}/p' panel-waveshare-dsi.c

B=$(basename "$(ls -d /sys/bus/i2c/devices/*-0045 2>/dev/null | head -1)" | cut -d- -f1)
L=/sys/class/leds
w(){ S i2cset -f -y "$B" 0x45 0x$1 0x$2 2>/dev/null && printf '    0x%s <- 0x%s  ok\n' "$1" "$2" || printf '    0x%s <- 0x%s  FAILED\n' "$1" "$2"; }
leds_off(){ for n in 1 2 3 4; do S sh -c "echo 0 > $L/media-carrier:green$n/brightness" 2>/dev/null; done; }
leds_n(){ leds_off; i=1; while [ $i -le $1 ]; do S sh -c "echo 255 > $L/media-carrier:green$i/brightness" 2>/dev/null; i=$((i+1)); done; }

echo
echo "bus=$B"
leds_off
echo "*** WATCH THE PANEL. Green LEDs count the phase. Starting in 5s ***"
sleep 5

echo "--- PHASE 1 (1 LED): protocol C power-on ---"
leds_n 1
w c0 01; sleep 1
w c2 01; sleep 1
w ac 01; sleep 1
w ad 01; sleep 4
leds_off; sleep 2

echo "--- PHASE 2 (2 LEDs): protocol C backlight sweep, DIM -> BRIGHT ---"
leds_n 2
for v in ff c0 80 40 00; do
    w ab $v
    w aa 01
    sleep 3
done
leds_off; sleep 2

echo "--- PHASE 3 (3 LEDs): protocol B (touch-a) registers ---"
leds_n 3
w 95 01; sleep 1      # REG_LCD
w 94 01; sleep 1      # REG_TP
for v in 00 40 80 ff; do w 96 $v; sleep 2; done   # REG_PWM
leds_off; sleep 2

echo "--- PHASE 4 (4 LEDs): protocol C alternate enable (0xad=0x02) + full bright ---"
leds_n 4
w ad 02; sleep 1
w ab 00; sleep 1
w aa 01; sleep 5
leds_off

echo
echo "=== leave everything at maximum brightness, all protocols ==="
w ab 00; w aa 01          # protocol C: 0x00 = brightest
w 96 ff                   # protocol B
w 86 ff                   # protocol A
BL=$(ls -d /sys/class/backlight/*/ 2>/dev/null | head -1)
[ -n "$BL" ] && S sh -c "echo 255 > $BL/brightness"

echo
echo "=== paint WHITE ==="
python3 -c "open('/dev/fb0','wb').write(bytes([255,255,255,255])*(800*480)); print('  painted WHITE')"

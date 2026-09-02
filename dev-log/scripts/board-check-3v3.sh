#!/bin/sh
# Runs ON the UNO Q. Stdin secrets contract: 1. sudo password  2. SSID  3. wifi pw
#
# The panel is powered from DSI pin 15 = 3V3 and draws ~1.2 W (~360 mA at 3.3 V).
# The carrier's DISPLAY connector offers +3V3 on pin 22.
# Question: what sources that rail, and can it deliver ~360 mA?
unset HISTFILE
IFS= read -r SUDO_PASS; IFS= read -r WIFI_SSID; IFS= read -r WIFI_PASS
cd /tmp || exit 1

echo "=== panel pinout, pins 13-15 (what is pin 14?) ==="
sed -n '/^ *13 *$/,/^ *Hardware Connection/p' ws.txt | head -12
echo "--- raw window ---"
grep -n -A14 "Interface Definition" ws.txt | sed -n '1,40p'

echo
echo "=== carrier schematic: the DSI flat-flex sheet ==="
grep -n -i -B5 -A40 "DSI_FLAT" ASX00083-schematics.txt | head -70

echo
echo "=== what feeds +3V3 on the carrier / any load switch or regulator ==="
grep -n -iE "PWR_3P3V|3V3|LDO|TPS[0-9]|load switch|current limit|regulator|AP2[0-9]|SY6|NCP" ASX00083-schematics.txt | head -40

echo
echo "=== datasheet: power output capability section ==="
grep -n -i -B4 -A25 "Power Output Capability" ASX00083-datasheet.txt | head -50

echo
echo "=== datasheet: 3.1 Power Rails table ==="
grep -n -A20 "3.1 Power Rails" ASX00083-datasheet.txt | head -30

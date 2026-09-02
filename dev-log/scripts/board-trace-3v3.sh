#!/bin/sh
# Runs ON the UNO Q. Stdin secrets contract: 1. sudo password  2. SSID  3. wifi pw
#
# Is there anything between the carrier's main PWR_3P3V rail and the DISPLAY
# connector's pin 22 - a ferrite, series resistor, load switch, or a separate
# low-current regulator? If pin 22 is tied straight to the main rail, then the
# "cannot supply ~360 mA" hypothesis is weak and I should drop it.
unset HISTFILE
IFS= read -r SUDO_PASS; IFS= read -r WIFI_SSID; IFS= read -r WIFI_PASS
cd /tmp || exit 1

echo "=== which connector designator is the DISPLAY (DSI0)? ==="
grep -n -B6 -A6 "PIJ4022\|PIJ302022" ASX00083-schematics.txt | head -40

echo
echo "=== the DSI connector sheet: components near it ==="
grep -n -iE "DSI_FLAT|DSI0|J4\b" ASX00083-schematics.txt | head -20

echo
echo "=== every net/part on the same lines as PWR_3P3V near a 22-pin connector ==="
grep -n -B3 -A3 "PWR_3P3V" ASX00083-schematics.txt | grep -iE "PWR_3P3V|FB[0-9]|L[0-9]+ |R[0-9]+ |C[0-9]+ |TPS|AP2|SY6|NCP|load|ferrite|bead" | head -40

echo
echo "=== any load switch / current limiter part numbers anywhere on the board ==="
grep -n -oiE "TPS[0-9A-Z]+|AP2[0-9A-Z]+|SY6[0-9A-Z]+|NCP[0-9A-Z]+|SiP[0-9A-Z]+|FPF[0-9A-Z]+|MIC[0-9]{4}" ASX00083-schematics.txt | sort -u | head -20

echo
echo "=== ferrite beads / inductors listed ==="
grep -n -oiE "ferrite|bead|BLM[0-9A-Z]+|MPZ[0-9A-Z]+" ASX00083-schematics.txt | sort -u | head -10

echo
echo "=== what the datasheet says about 3V3 output capability ==="
grep -n -B4 -A18 "Power Output Capability" carrier.txt 2>/dev/null | head -40
grep -n -B2 -A14 "3.1 Power Rails" carrier.txt 2>/dev/null | head -25

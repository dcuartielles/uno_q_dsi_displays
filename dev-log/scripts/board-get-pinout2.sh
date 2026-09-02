#!/bin/sh
# Runs ON the UNO Q. Stdin secrets contract: 1. sudo password  2. SSID  3. wifi pw
# Dig out the DSI connector pin table and the power tree from the carrier datasheet.
unset HISTFILE
IFS= read -r SUDO_PASS; IFS= read -r WIFI_SSID; IFS= read -r WIFI_PASS

cd /tmp || exit 1

echo "=== all section headings ==="
grep -nE "^\s*[0-9]+(\.[0-9]+)*\s+[A-Z]" carrier.txt | head -50

echo
echo "=== every mention of a power rail ==="
grep -n -iE "5 ?V|3V3|3\.3 ?V|VBUS|VSYS|VDD|power tree|DC IN|VIN" carrier.txt | head -50

echo
echo "=== DSI0 pin table (searching for pin-numbered rows near DSI) ==="
grep -n -A45 "4.5 Display Interface" carrier.txt | head -60

echo
echo "=== any 22-pin connector pin listing anywhere ==="
grep -n -B3 -A28 -iE "DSI0|Display Connector Pinout|J[0-9]*DSI" carrier.txt | sed -n '1,140p'

echo
echo "=== power consumption / current limits ==="
grep -n -i -B3 -A12 "consumption\|current\|mA\|Power Rails" carrier.txt | head -60

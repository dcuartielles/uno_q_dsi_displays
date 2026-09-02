#!/bin/sh
# Runs ON the UNO Q. Stdin secrets contract: 1. sudo password  2. SSID  3. wifi pw
# Exact pinout of the carrier's power headers (J13 / J10) and the DISPLAY connector.
unset HISTFILE
IFS= read -r SUDO_PASS; IFS= read -r WIFI_SSID; IFS= read -r WIFI_PASS
cd /tmp || exit 1

echo "############ DISPLAY connector, full 22 pins ############"
grep -n -B30 -A6 "^\s*98:\|DISPLAY" ASX00083-full-pinout.txt 2>/dev/null | sed -n '1,60p'
echo
echo "--- raw window around the DISPLAY block ---"
sed -n '90,150p' ASX00083-full-pinout.txt

echo
echo "############ Power headers (J13 / J10) ############"
grep -n -i -B8 -A18 "Power Distribution Header\|Low Voltage Power Header" ASX00083-datasheet.txt 2>/dev/null | head -70

echo
echo "--- pinout doc: power header block ---"
sed -n '30,60p' ASX00083-full-pinout.txt

echo
echo "############ any 5V on the carrier for peripherals ############"
grep -n -i "5V" ASX00083-full-pinout.txt | head -20

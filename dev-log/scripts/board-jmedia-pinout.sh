#!/bin/sh
# Runs ON the UNO Q. Stdin secrets contract: 1. sudo password  2. SSID  3. wifi pw
# Exact JMEDIA (60-pin) pin numbers for the MIPI-DSI differential pairs.
unset HISTFILE
IFS= read -r SUDO_PASS; IFS= read -r WIFI_SSID; IFS= read -r WIFI_PASS

cd "$HOME/carrier-docs" 2>/dev/null || { mkdir -p "$HOME/carrier-docs"; cd "$HOME/carrier-docs" || exit 1; }
B=https://docs.arduino.cc/resources
[ -s ASX00083-full-pinout.pdf ] || curl -fsSL --max-time 120 "$B/pinouts/ASX00083-full-pinout.pdf" -o ASX00083-full-pinout.pdf 2>/dev/null
[ -s ASX00083-full-pinout.txt ] || pdftotext -layout ASX00083-full-pinout.pdf ASX00083-full-pinout.txt 2>/dev/null
[ -s carrier-datasheet.txt ] || { curl -fsSL --max-time 120 "https://botland.com.pl/img/cms/products_28653/ASX00083-datasheet.pdf" -o carrier-datasheet.pdf 2>/dev/null; pdftotext -layout carrier-datasheet.pdf carrier-datasheet.txt 2>/dev/null; }
ls -la *.txt 2>/dev/null

echo
echo "############ JMEDIA: every line mentioning a DSI pair ############"
grep -n -iE "DSI0?_(D[0-3]|CLK|L[0-3])|MIPI_DSI" ASX00083-full-pinout.txt | head -40

echo
echo "############ JMEDIA header block from the pinout doc ############"
grep -n -B4 -A60 "JMEDIA" ASX00083-full-pinout.txt | head -90

echo
echo "############ datasheet 5.4.2 MIPI CSI/DSI Differential Pairs ############"
grep -n -A30 "5.4.2" carrier-datasheet.txt 2>/dev/null | head -40

echo
echo "############ datasheet: JMEDIA pin table ############"
grep -n -B3 -A40 "5.4 JMEDIA" carrier-datasheet.txt 2>/dev/null | head -60

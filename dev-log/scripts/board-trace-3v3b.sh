#!/bin/sh
# Runs ON the UNO Q. Stdin secrets contract: 1. sudo password  2. SSID  3. wifi pw
# Re-fetch the carrier schematic + datasheet (lost on reboot) and work out what
# feeds the DISPLAY connector's +3V3 pin.
unset HISTFILE
IFS= read -r SUDO_PASS; IFS= read -r WIFI_SSID; IFS= read -r WIFI_PASS

mkdir -p "$HOME/carrier-docs" && cd "$HOME/carrier-docs" || exit 1
B=https://docs.arduino.cc/resources

for f in schematics/ASX00083-schematics.pdf pinouts/ASX00083-full-pinout.pdf; do
    n=$(basename "$f")
    [ -s "$n" ] || curl -fsSL --max-time 120 "$B/$f" -o "$n" 2>/dev/null
    [ -s "$n" ] && echo "have $n ($(stat -c%s "$n") bytes)" || echo "MISSING $n"
done
[ -s carrier-datasheet.pdf ] || curl -fsSL --max-time 120 \
    "https://botland.com.pl/img/cms/products_28653/ASX00083-datasheet.pdf" -o carrier-datasheet.pdf 2>/dev/null

for p in *.pdf; do
    t="${p%.pdf}.txt"
    [ -s "$t" ] || pdftotext -layout "$p" "$t" 2>/dev/null
done
ls -la *.txt

S=ASX00083-schematics.txt

echo
echo "=== the DISPLAY connector in the schematic: designator + pin 22 net ==="
grep -n -B8 -A8 "PIJ4022" "$S" 2>/dev/null | head -40

echo
echo "=== all references to the DSI flat-flex connector ==="
grep -n -iE "DSI_FLAT|CODSI|COJ4\b|J4 " "$S" 2>/dev/null | head -20

echo
echo "=== power components on the board (load switches / regulators / ferrites) ==="
grep -oiE "TPS[0-9A-Z]{3,}|AP2[0-9A-Z]{3,}|SY6[0-9A-Z]{3,}|NCP[0-9A-Z]{3,}|FPF[0-9A-Z]{3,}|SGM[0-9A-Z]{3,}|BLM[0-9A-Z]+|MPZ[0-9A-Z]+|TCA9406|LSF[0-9]+" "$S" 2>/dev/null | sort | uniq -c | sort -rn | head -20

echo
echo "=== what nets appear alongside PWR_3P3V (looking for series parts) ==="
grep -n "PWR_3P3V" "$S" 2>/dev/null | head -30

echo
echo "=== datasheet: power rails + output capability ==="
D=carrier-datasheet.txt
grep -n -A16 "3.1 Power Rails" "$D" 2>/dev/null | head -22
echo "---"
grep -n -B3 -A20 "Power Output Capability" "$D" 2>/dev/null | head -30

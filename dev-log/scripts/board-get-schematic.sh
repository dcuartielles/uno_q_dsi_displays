#!/bin/sh
# Runs ON the UNO Q. Stdin secrets contract: 1. sudo password  2. SSID  3. wifi pw
# Fetch the carrier schematic / full pinout and find what the DSI connector
# supplies on its power pins.
unset HISTFILE
IFS= read -r SUDO_PASS; IFS= read -r WIFI_SSID; IFS= read -r WIFI_PASS

cd /tmp || exit 1
B=https://docs.arduino.cc/resources
for u in \
    "$B/schematics/ASX00083-schematics.pdf" \
    "$B/pinouts/ASX00083-full-pinout.pdf" \
    "$B/pinouts/ASX00083-pinout.pdf" \
    "$B/datasheets/ASX00083-datasheet.pdf" ; do
    f=$(basename "$u")
    printf '=== %s : ' "$f"
    if curl -fsSL --max-time 60 -o "$f" "$u" 2>/dev/null && [ -s "$f" ]; then
        echo "OK ($(stat -c%s "$f") bytes)"
    else
        echo "not available"
        rm -f "$f"
    fi
done

echo
for f in ASX00083-schematics.pdf ASX00083-full-pinout.pdf ASX00083-pinout.pdf; do
    [ -f "$f" ] || continue
    echo "############ $f ############"
    pdftotext -layout "$f" "${f%.pdf}.txt" 2>/dev/null
    t="${f%.pdf}.txt"
    [ -f "$t" ] || continue
    echo "--- lines mentioning DSI ---"
    grep -n -i -B3 -A12 "DSI" "$t" | head -80
    echo
    echo "--- power rails near the display connector ---"
    grep -n -iE "5V|3V3|3\.3V|VCC|VDD|LCD|PANEL|BACKLIGHT|DISP" "$t" | head -40
    echo
done

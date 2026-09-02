#!/bin/sh
# Runs ON the UNO Q. Stdin secrets contract: 1. sudo password  2. SSID  3. wifi pw
# Get RPi's panel-simple entry for "raspberrypi,7inch-dsi" - exact timings,
# bus_format, bpc and connector type - plus their edt-ft5406 dtsi.
unset HISTFILE
IFS= read -r SUDO_PASS; IFS= read -r WIFI_SSID; IFS= read -r WIFI_PASS

cd /tmp/rpi || exit 1
BR=rpi-6.12.y
R=https://raw.githubusercontent.com/raspberrypi/linux/$BR

curl -fsSL --max-time 90 "$R/drivers/gpu/drm/panel/panel-simple.c" -o rpi-panel-simple.c 2>/dev/null \
    && echo "panel-simple.c: $(wc -l < rpi-panel-simple.c) lines" || echo "fetch failed"
curl -fsSL --max-time 60 "$R/arch/arm/boot/dts/overlays/edt-ft5406.dtsi" -o edt-ft5406.dtsi 2>/dev/null \
    && echo "edt-ft5406.dtsi fetched" || echo "(edt-ft5406.dtsi not found)"

echo
echo "############ raspberrypi,7inch-dsi panel entry ############"
grep -n -B45 '"raspberrypi,7inch-dsi"' rpi-panel-simple.c | tail -55

echo
echo "############ the mode/desc it references ############"
grep -n -B4 -A40 "rpi_7inch" rpi-panel-simple.c | head -60

echo
echo "############ edt-ft5406.dtsi (touch node) ############"
cat edt-ft5406.dtsi 2>/dev/null

echo
echo "############ does MAINLINE panel-simple know raspberrypi,7inch-dsi? ############"
if [ -f /tmp/ps.c ]; then
    grep -c "raspberrypi,7inch-dsi" /tmp/ps.c || echo "0 - mainline does NOT have it"
else
    echo "(mainline copy not present at /tmp/ps.c)"
fi

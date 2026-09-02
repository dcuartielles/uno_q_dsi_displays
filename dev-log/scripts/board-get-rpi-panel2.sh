#!/bin/sh
# Runs ON the UNO Q. Stdin secrets contract: 1. sudo password  2. SSID  3. wifi pw
# Extract the raspberrypi,7inch-dsi panel descriptor: timings, bus_format, bpc.
unset HISTFILE
IFS= read -r SUDO_PASS; IFS= read -r WIFI_SSID; IFS= read -r WIFI_PASS
cd /tmp/rpi || exit 1

echo "=== the of_match entry and its .data ==="
grep -n -A3 '"raspberrypi,7inch-dsi"' rpi-panel-simple.c

echo
echo "=== the descriptor struct ==="
NAME=$(grep -A2 '"raspberrypi,7inch-dsi"' rpi-panel-simple.c | grep -o '&[a-z0-9_]*' | head -1 | tr -d '&')
echo "descriptor name: $NAME"
grep -n -B8 -A40 "struct panel_desc $NAME" rpi-panel-simple.c

echo
echo "=== the display mode it points at ==="
MODE=$(grep -A20 "struct panel_desc $NAME" rpi-panel-simple.c | grep -o '&[a-z0-9_]*_mode' | head -1 | tr -d '&')
echo "mode name: $MODE"
grep -n -B4 -A25 "$MODE\[\]\|drm_display_mode $MODE" rpi-panel-simple.c | head -40

echo
echo "=== for comparison: what OUR overlay currently uses ==="
echo "  clock 25979400  hactive 800  hfp 1  hsync 2  hbp 46"
echo "                  vactive 480  vfp 7  vsync 2  vbp 21"

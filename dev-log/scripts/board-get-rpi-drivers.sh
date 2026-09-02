#!/bin/sh
# Runs ON the UNO Q. Stdin secrets contract: 1. sudo password  2. SSID  3. wifi pw
#
# Fetch the RASPBERRY PI DOWNSTREAM drivers for the 7"/5" DSI panel and compare
# them with the mainline ones we built. Waveshare tell you to use
# `dtoverlay=vc4-kms-dsi-7inch`, which is RPi's own overlay + drivers - NOT the
# mainline tc358762 + rpi-panel-attiny-regulator combination we used.
unset HISTFILE
IFS= read -r SUDO_PASS; IFS= read -r WIFI_SSID; IFS= read -r WIFI_PASS

cd /tmp || exit 1
mkdir -p rpi && cd rpi || exit 1
BR=rpi-6.12.y
R=https://raw.githubusercontent.com/raspberrypi/linux/$BR

get() {
    printf '=== %-45s ' "$(basename "$1")"
    if curl -fsSL --max-time 60 "$R/$1" -o "$(basename "$1")" 2>/dev/null && [ -s "$(basename "$1")" ]; then
        echo "OK ($(wc -l < "$(basename "$1")") lines)"
    else
        echo "NOT FOUND"
    fi
}

get drivers/regulator/rpi-panel-attiny-regulator.c
get drivers/gpu/drm/panel/panel-raspberrypi-touchscreen.c
get arch/arm/boot/dts/overlays/vc4-kms-dsi-7inch-overlay.dts

echo
echo "############ RPi overlay: what does it actually instantiate? ############"
cat vc4-kms-dsi-7inch-overlay.dts 2>/dev/null

echo
echo "############ RPi attiny regulator: the ENABLE sequence ############"
grep -n -B4 -A45 "attiny_lcd_power_enable" rpi-panel-attiny-regulator.c 2>/dev/null | head -70

echo
echo "############ RPi attiny: version handling / is_v2 ############"
grep -n -B3 -A20 "0xde\|is_v2\|0xc3" rpi-panel-attiny-regulator.c 2>/dev/null | head -60

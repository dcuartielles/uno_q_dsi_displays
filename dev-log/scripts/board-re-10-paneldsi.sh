#!/bin/sh
# Runs ON the UNO Q. Stdin secrets contract: 1. sudo password  2. SSID  3. wifi pw
#
# RPi drives this panel as a DIRECT DSI panel ("panel-dsi" generic binding),
# with NO bridge node. Does kernel 7.0 support that compatible?
unset HISTFILE
IFS= read -r SUDO_PASS; SUDO_PASS=$(printf '%s' "$SUDO_PASS" | tr -d '\r')
IFS= read -r WIFI_SSID
IFS= read -r WIFI_PASS
S() { printf '%s\n' "$SUDO_PASS" | sudo -S -p '' "$@"; }

K=$(uname -r)
echo "=== does anything claim 'panel-dsi' or the waveshare dsi compatibles? ==="
grep -iE 'panel-dsi|waveshare,.*inch-dsi' /lib/modules/"$K"/modules.alias | head -10
echo "--- simple-panel / panel-simple-dsi modules present? ---"
ls /lib/modules/"$K"/kernel/drivers/gpu/drm/panel/ | grep -iE 'simple|dsi'

D="$HOME/re"; mkdir -p "$D"; cd "$D" || exit 1
MLN=https://raw.githubusercontent.com/arduino/linux-qcom/122c2c22d838
RPI=https://raw.githubusercontent.com/raspberrypi/linux/rpi-6.12.y

echo
echo "=== mainline: is there a panel-simple-dsi / panel-dsi driver? ==="
[ -s ml-panel-simple-dsi.c ] || curl -fsSL --max-time 60 "$MLN/drivers/gpu/drm/panel/panel-simple.c" -o ml-panel-simple.c 2>/dev/null
grep -n '"panel-dsi"\|panel_dsi\|MODE_VIDEO\|dsi-color-format' ml-panel-simple.c 2>/dev/null | head -20
echo "--- mainline binding for panel-dsi? ---"
curl -fsSL --max-time 40 "$MLN/Documentation/devicetree/bindings/display/panel/panel-dsi.yaml" -o ml-panel-dsi.yaml 2>/dev/null \
  && echo "  binding EXISTS in mainline ($(wc -l < ml-panel-dsi.yaml) lines)" \
  || echo "  no panel-dsi.yaml in mainline"

echo
echo "=== RPi: which driver implements panel-dsi? ==="
[ -s rpi-panel-simple.c ] || curl -fsSL --max-time 90 "$RPI/drivers/gpu/drm/panel/panel-simple.c" -o rpi-panel-simple.c 2>/dev/null
grep -n '"panel-dsi"\|waveshare,4-3-inch-dsi\|dsi-color-format\|MODE_VIDEO' rpi-panel-simple.c 2>/dev/null | head -20

echo
echo "=== RPi: the generic panel-dsi handling (how it parses the DT) ==="
grep -n -B4 -A30 'panel_dsi_probe\|"panel-dsi"' rpi-panel-simple.c 2>/dev/null | head -60

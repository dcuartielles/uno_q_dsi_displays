#!/bin/sh
# Runs ON the UNO Q. Stdin secrets contract: 1. sudo password  2. SSID  3. wifi pw
#
# The panel reportedly carries a Chipone ICN6211 (or ICN2611) DSI-to-RGB bridge,
# NOT the Toshiba TC358762 our overlay declares. Check what the kernel offers
# and pull the driver + binding so we can rewrite the overlay.
unset HISTFILE
IFS= read -r SUDO_PASS; SUDO_PASS=$(printf '%s' "$SUDO_PASS" | tr -d '\r')
IFS= read -r WIFI_SSID
IFS= read -r WIFI_PASS
S() { printf '%s\n' "$SUDO_PASS" | sudo -S -p '' "$@"; }

K=$(uname -r)
echo "=== is a chipone/icn6211 driver present in kernel $K? ==="
find /lib/modules/"$K" -iname '*chipone*' -o -iname '*icn6211*' -o -iname '*icn*' 2>/dev/null
echo "--- builtin? ---"
grep -iE 'chipone|icn6211' /lib/modules/"$K"/modules.builtin 2>/dev/null
echo "--- module aliases ---"
grep -iE 'chipone|icn6211' /lib/modules/"$K"/modules.alias 2>/dev/null | head

echo
echo "=== all bridge drivers available ==="
ls /lib/modules/"$K"/kernel/drivers/gpu/drm/bridge/ 2>/dev/null

D="$HOME/re"; mkdir -p "$D"; cd "$D" || exit 1
MLN=https://raw.githubusercontent.com/arduino/linux-qcom/122c2c22d838

echo
echo "=== fetching the mainline driver + binding ==="
[ -s chipone-icn6211.c ] || curl -fsSL --max-time 60 "$MLN/drivers/gpu/drm/bridge/chipone-icn6211.c" -o chipone-icn6211.c 2>/dev/null
[ -s chipone,icn6211.yaml ] || curl -fsSL --max-time 60 "$MLN/Documentation/devicetree/bindings/display/bridge/chipone,icn6211.yaml" -o icn6211.yaml 2>/dev/null
printf '  chipone-icn6211.c : %s lines\n' "$(wc -l < chipone-icn6211.c 2>/dev/null || echo MISSING)"
printf '  binding yaml      : %s lines\n' "$(wc -l < icn6211.yaml 2>/dev/null || echo MISSING)"

echo
echo "############ how the driver attaches: I2C or DSI? ############"
grep -n -B3 -A12 'of_device_id\|i2c_device_id\|mipi_dsi_driver\|i2c_driver' chipone-icn6211.c 2>/dev/null | head -50

echo
echo "############ required DT properties (binding) ############"
sed -n '1,120p' icn6211.yaml 2>/dev/null

echo
echo "############ the binding's example ############"
sed -n '/examples:/,$p' icn6211.yaml 2>/dev/null | head -60

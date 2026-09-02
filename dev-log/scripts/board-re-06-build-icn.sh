#!/bin/sh
# Runs ON the UNO Q. Stdin secrets contract: 1. sudo password  2. SSID  3. wifi pw
#
# CONFIRMED: the panel carries a Chipone ICN6211 DSI-to-RGB bridge, not a
# Toshiba TC358762. Build the mainline chipone-icn6211 driver (absent from
# kernel 7.0) and report how it configures the DSI link, so the overlay can
# be written correctly.
unset HISTFILE
IFS= read -r SUDO_PASS; SUDO_PASS=$(printf '%s' "$SUDO_PASS" | tr -d '\r')
IFS= read -r WIFI_SSID
IFS= read -r WIFI_PASS
S() { printf '%s\n' "$SUDO_PASS" | sudo -S -p '' "$@"; }
S true 2>/dev/null || { echo "SUDO PASSWORD REJECTED"; exit 1; }

K=$(uname -r)
SRC="$HOME/panel-build"
cp "$HOME/re/chipone-icn6211.c" "$SRC/" 2>/dev/null || {
    curl -fsSL --max-time 60 \
      "https://raw.githubusercontent.com/arduino/linux-qcom/122c2c22d838/drivers/gpu/drm/bridge/chipone-icn6211.c" \
      -o "$SRC/chipone-icn6211.c" 2>/dev/null; }
cd "$SRC" || exit 1
printf 'chipone-icn6211.c: %s lines\n' "$(wc -l < chipone-icn6211.c)"

echo
echo "############ how it configures the DSI link (lanes / format / flags) ############"
grep -n -B4 -A14 'dsi->lanes\|dsi->format\|dsi->mode_flags' chipone-icn6211.c | head -50

echo
echo "############ does it read data-lanes from DT? ############"
grep -n -B3 -A12 'data-lanes\|data_lanes\|of_property.*lanes' chipone-icn6211.c | head -30

echo
echo "############ enable-gpios / supplies handling ############"
grep -n -B2 -A8 'enable.*gpio\|vdd1\|vdd2\|vdd3\|devm_gpiod_get' chipone-icn6211.c | head -40

echo
echo "############ the bridge funcs (where init happens) ############"
grep -n -A14 'chipone_bridge_funcs = {' chipone-icn6211.c

echo
echo "=== add it to the module build ==="
grep -q 'chipone-icn6211' Makefile 2>/dev/null || \
    sed -i '1i obj-m += chipone-icn6211.o' Makefile
cat Makefile

echo
echo "=== build ==="
make -C "/lib/modules/$K/build" M="$PWD" modules 2>&1 | tail -12
ls -la chipone-icn6211.ko 2>/dev/null || echo ">>> BUILD FAILED"

if [ -f chipone-icn6211.ko ]; then
    echo
    echo "=== install ==="
    S cp chipone-icn6211.ko "/lib/modules/$K/extra/"
    S depmod -a
    echo "--- what compatible does it claim? ---"
    S modinfo chipone-icn6211 2>/dev/null | grep -E '^alias|^filename|^description'
    grep -iE 'chipone|icn6211' /lib/modules/"$K"/modules.alias | head
fi

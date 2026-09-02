#!/bin/sh
# Runs ON the UNO Q. Stdin secrets contract: 1. sudo password  2. SSID  3. wifi pw
#
# REVERSE ENGINEERING, STEP 1: recon.
#
# a) Read the register map of the KNOWN Waveshare controller protocol, as
#    implemented by gpio-waveshare-dsi.c (shipped in kernel 7.0) and RPi's
#    panel-waveshare-dsi.c. If our chip is a Waveshare variant, this is its map.
# b) Dump every register of our chip at 0x45 so we can compare.
unset HISTFILE
IFS= read -r SUDO_PASS; SUDO_PASS=$(printf '%s' "$SUDO_PASS" | tr -d '\r')
IFS= read -r WIFI_SSID
IFS= read -r WIFI_PASS
S() { printf '%s\n' "$SUDO_PASS" | sudo -S -p '' "$@"; }
S true 2>/dev/null || { echo "SUDO PASSWORD REJECTED"; exit 1; }

D="$HOME/re"; mkdir -p "$D"; cd "$D" || exit 1
MLN=https://raw.githubusercontent.com/arduino/linux-qcom/122c2c22d838
RPI=https://raw.githubusercontent.com/raspberrypi/linux/rpi-6.12.y

echo "=== fetching the known Waveshare driver sources ==="
[ -s gpio-waveshare-dsi.c ] || curl -fsSL --max-time 60 "$MLN/drivers/gpio/gpio-waveshare-dsi.c" -o gpio-waveshare-dsi.c 2>/dev/null
[ -s panel-waveshare-dsi.c ] || curl -fsSL --max-time 60 "$RPI/drivers/gpu/drm/panel/panel-waveshare-dsi.c" -o panel-waveshare-dsi.c 2>/dev/null
for f in gpio-waveshare-dsi.c panel-waveshare-dsi.c; do
    printf '  %-28s %s\n' "$f" "$([ -s $f ] && wc -l < $f || echo MISSING)"
done

echo
echo "############ gpio-waveshare-dsi.c : register map ############"
grep -nE '#define|reg|0x[0-9a-fA-F]{2}' gpio-waveshare-dsi.c 2>/dev/null | head -50

echo
echo "############ gpio-waveshare-dsi.c : how it writes ############"
grep -n -B3 -A22 'i2c_smbus_write\|i2c_transfer\|regmap_write\|_set(' gpio-waveshare-dsi.c 2>/dev/null | head -60

echo
echo "############ panel-waveshare-dsi.c : register map (RPi) ############"
grep -nE '#define (WS_|REG_)|0x[0-9a-fA-F]{2},' panel-waveshare-dsi.c 2>/dev/null | head -40

echo
echo "############ panel-waveshare-dsi.c : the write helper ############"
grep -n -B3 -A20 'static .*_write\|i2c_smbus_write' panel-waveshare-dsi.c 2>/dev/null | head -40

B=$(basename "$(ls -d /sys/bus/i2c/devices/*-0045 2>/dev/null | head -1)" | cut -d- -f1)
echo
echo "############ OUR CHIP @0x45 on bus $B : full register dump ############"
S i2cdump -f -y "$B" 0x45 b 2>&1 | head -20

echo
echo "############ which registers return something other than 0xff ############"
for hi in 0 1 2 3 4 5 6 7 8 9 a b c d e f; do
  for lo in 0 1 2 3 4 5 6 7 8 9 a b c d e f; do
    r="$hi$lo"
    v=$(S i2cget -f -y "$B" 0x45 0x$r 2>/dev/null)
    case "$v" in ""|0xff) ;; *) printf '  0x%s = %s\n' "$r" "$v";; esac
  done
done

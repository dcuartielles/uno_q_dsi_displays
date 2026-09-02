#!/bin/sh
# Runs ON the UNO Q. Stdin secrets contract: 1. sudo password  2. SSID  3. wifi pw
# Print both ISRs so the staged-read logic can be ported exactly.
unset HISTFILE
IFS= read -r SUDO_PASS; IFS= read -r WIFI_SSID; IFS= read -r WIFI_PASS

echo "############ MAINLINE edt_ft5x06_ts_isr ############"
sed -n '/static irqreturn_t edt_ft5x06_ts_isr/,/^}/p' "$HOME/panel-build/edt-ft5x06.c"

echo
echo "############ RPi edt_ft5x06_ts_isr ############"
sed -n '/static irqreturn_t edt_ft5x06_ts_isr/,/^}/p' "$HOME/driver-compare/rpi/edt-ft5x06.c"

echo
echo "############ RPi struct fields we may need ############"
grep -n 'known_ids\|init_td_status' "$HOME/driver-compare/rpi/edt-ft5x06.c" | head

echo
echo "############ tdata_cmd / tdata_len / tdata_offset / point_len values ############"
grep -n 'tdata_cmd\|tdata_len\|tdata_offset\|point_len' "$HOME/panel-build/edt-ft5x06.c" | head -20

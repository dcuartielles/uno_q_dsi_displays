#!/bin/sh
# Runs ON the UNO Q. Stdin secrets contract: 1. sudo password  2. SSID  3. wifi pw
# How does RPi's tc358762 obtain ctx->mode, and what exactly does init write?
unset HISTFILE
IFS= read -r SUDO_PASS; IFS= read -r WIFI_SSID; IFS= read -r WIFI_PASS
cd "$HOME/driver-compare" || exit 1

echo "############ RPi: struct tc358762 ############"
grep -n -A14 "^struct tc358762" rpi/tc358762.c

echo
echo "############ RPi: mode_set / where ctx->mode is filled ############"
grep -n -B4 -A18 "mode_set\|ctx->mode" rpi/tc358762.c | head -60

echo
echo "############ RPi: full tc358762_init() ############"
sed -n '/static int tc358762_init/,/^}/p' rpi/tc358762.c

echo
echo "############ RPi: bridge_funcs ############"
grep -n -A14 "tc358762_bridge_funcs = {" rpi/tc358762.c

echo
echo "############ MAINLINE: struct + init + funcs (what we built) ############"
grep -n -A12 "^struct tc358762" mainline/tc358762.c
echo "--- init ---"
sed -n '/static int tc358762_init/,/^}/p' mainline/tc358762.c
echo "--- funcs ---"
grep -n -A14 "tc358762_bridge_funcs = {" mainline/tc358762.c

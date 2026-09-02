#!/bin/sh
# Runs ON the UNO Q. Stdin secrets contract: 1. sudo password  2. SSID  3. wifi pw
# status=4 is DSI_ERR_STATE_FIFO in this kernel. What raises it, exactly?
unset HISTFILE
IFS= read -r SUDO_PASS; IFS= read -r WIFI_SSID; IFS= read -r WIFI_PASS
cd "$HOME/driver-compare" || exit 1

echo "############ dsi_fifo_status() - what sets DSI_ERR_STATE_FIFO ############"
sed -n '/static void dsi_fifo_status/,/^}/p' dsi_host.c

echo
echo "############ the error IRQ dispatcher ############"
sed -n '/static void dsi_error_handler/,/^}/p' dsi_host.c

echo
echo "############ FIFO_STATUS register bit names ############"
[ -s dsi.xml ] || curl -fsSL --max-time 60 \
  "https://raw.githubusercontent.com/arduino/linux-qcom/122c2c22d838/drivers/gpu/drm/msm/registers/display/dsi.xml" -o dsi.xml 2>/dev/null
grep -n -A20 'name="FIFO_STATUS"' dsi.xml 2>/dev/null | head -28

echo
echo "############ where the MDP_FIFO_UNDERFLOW path differs ############"
sed -n '1550,1565p' dsi_host.c

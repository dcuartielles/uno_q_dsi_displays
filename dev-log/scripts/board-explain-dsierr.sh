#!/bin/sh
# Runs ON the UNO Q. Stdin secrets contract: 1. sudo password  2. SSID  3. wifi pw
# What exactly does dsi_err_worker status=4 mean, per our kernel's own source?
unset HISTFILE
IFS= read -r SUDO_PASS; SUDO_PASS=$(printf '%s' "$SUDO_PASS" | tr -d '\r')
IFS= read -r WIFI_SSID
IFS= read -r WIFI_PASS
S() { printf '%s\n' "$SUDO_PASS" | sudo -S -p '' "$@"; }

D="$HOME/driver-compare"; mkdir -p "$D"; cd "$D" || exit 1
MLN=https://raw.githubusercontent.com/arduino/linux-qcom/122c2c22d838
[ -s dsi_host.c ] || curl -fsSL --max-time 90 "$MLN/drivers/gpu/drm/msm/dsi/dsi_host.c" -o dsi_host.c 2>/dev/null
[ -s dsi.xml.h ] || curl -fsSL --max-time 90 "$MLN/drivers/gpu/drm/msm/registers/display/dsi.xml" -o dsi.xml 2>/dev/null
echo "dsi_host.c: $(wc -l < dsi_host.c 2>/dev/null) lines"

echo
echo "############ the error-state bit definitions ############"
grep -n "DSI_ERR_STATE_" dsi_host.c | head -12

echo
echo "############ what sets DSI_ERR_STATE_DLN0_PHY (our status=4) ############"
sed -n '/static void dsi_dln0_phy_err/,/^}/p' dsi_host.c

echo
echo "############ dsi_err_worker: what it does about it ############"
sed -n '/static void dsi_err_worker/,/^}/p' dsi_host.c

echo
echo "############ did the kernel log the DETAILED sub-status? ############"
dmesg | grep -i "dln0_phy_err" || echo "  (no dln0_phy_err line - it is pr_err_ratelimited)"

echo
echo "############ all msm dsi / drm errors this boot ############"
dmesg | grep -iE "dsi|dpu|drm" | grep -iE "err|fail|timeout|underflow|contention" | tail -15

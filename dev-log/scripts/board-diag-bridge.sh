#!/bin/sh
# Runs ON the UNO Q. Stdin secrets contract: 1. sudo password  2. SSID  3. wifi pw
#
# Is the TC358762 actually powered and out of reset, and does a fresh modeset
# drive the DSI link cleanly?
#
# dsi_err_worker status bits (msm dsi_host.c):
#   0x01 ACK   0x02 TIMEOUT   0x04 DLN0_PHY   0x08 FIFO
#   0x10 MDP_FIFO_UNDERFLOW   0x20 INTERLEAVE   0x40 PLL_UNLOCKED
# status=4 => data lane 0 PHY error
unset HISTFILE
IFS= read -r SUDO_PASS; SUDO_PASS=$(printf '%s' "$SUDO_PASS" | tr -d '\r')
IFS= read -r WIFI_SSID
IFS= read -r WIFI_PASS
S() { printf '%s\n' "$SUDO_PASS" | sudo -S -p '' "$@"; }
S true 2>/dev/null || { echo "SUDO PASSWORD REJECTED"; exit 1; }

echo "=== ATTINY gpio lines: who holds them, what value? ==="
S gpioinfo gpiochip3 2>&1
echo "--- and the carrier expander for comparison ---"
S gpioinfo gpiochip2 2>&1 | head -6

echo
echo "=== regulator detail ==="
for r in /sys/class/regulator/*/; do
    n=$(cat "$r/name" 2>/dev/null)
    case "$n" in *tc358762*)
        echo "  name=$n state=$(cat "$r/state" 2>/dev/null) num_users=$(cat "$r/num_users" 2>/dev/null)";;
    esac
done

echo
echo "=== stop the desktop so we own the DRM device ==="
S systemctl stop lightdm 2>&1
sleep 2

echo
echo "=== enable DRM debug (driver + kms + atomic) ==="
S sh -c 'echo 0x1e > /sys/module/drm/parameters/debug'
S dmesg -C

echo
echo "=== force a fresh modeset with modetest for 12s ==="
if command -v modetest >/dev/null 2>&1; then
    S sh -c 'timeout 12 modetest -M msm -s 34@47:800x480 -v' 2>&1 | head -25
else
    echo "modetest NOT installed"
fi

echo
echo "=== turn DRM debug back off ==="
S sh -c 'echo 0 > /sys/module/drm/parameters/debug'

echo
echo "=== what the bridge/panel did during that modeset ==="
S dmesg | grep -iE 'tc358762|attiny|panel|bridge|dsi|dpu|drm' | head -60

echo
echo "=== dsi errors ==="
S dmesg | grep -i 'dsi_err' | tail -5

echo
echo "=== restart the desktop ==="
S systemctl start lightdm 2>&1
echo done

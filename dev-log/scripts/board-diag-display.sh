#!/bin/sh
# Runs ON the UNO Q. Stdin secrets contract: 1. sudo password  2. SSID  3. wifi pw
# Why is the panel enumerated but dark?
unset HISTFILE

IFS= read -r SUDO_PASS; SUDO_PASS=$(printf '%s' "$SUDO_PASS" | tr -d '\r')
IFS= read -r WIFI_SSID
IFS= read -r WIFI_PASS

S() { printf '%s\n' "$SUDO_PASS" | sudo -S -p '' "$@"; }
S true 2>/dev/null || { echo "SUDO PASSWORD REJECTED"; exit 1; }

echo "=== install modetest ==="
S env DEBIAN_FRONTEND=noninteractive apt-get -y install libdrm-tests 2>&1 | tail -3

echo
echo "=== full dmesg for the bridge + panel + attiny ==="
S dmesg | grep -iE "tc358762|attiny|panel-simple|panel-dpi|regulator|bridge" | tail -25

echo
echo "=== atomic state: is a CRTC actually active? ==="
S cat /sys/kernel/debug/dri/0/state 2>/dev/null | head -60

echo
echo "=== modetest: connectors and modes ==="
S modetest -M msm -c 2>&1 | head -40

echo
echo "=== modetest: encoders/crtcs ==="
S modetest -M msm -e 2>&1 | head -15

echo
echo "=== attiny regulator + backlight sysfs ==="
S cat /sys/class/backlight/0-0045/brightness /sys/class/backlight/0-0045/bl_power 2>/dev/null
S ls /sys/class/regulator/ | head -30
for r in /sys/class/regulator/*/; do
    n=$(cat "$r/name" 2>/dev/null)
    case "$n" in *tc358762*|*attiny*) echo "$n: state=$(cat "$r/state" 2>/dev/null)";; esac
done

echo
echo "=== done ==="

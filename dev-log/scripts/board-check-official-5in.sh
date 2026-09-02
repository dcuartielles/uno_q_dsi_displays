#!/bin/sh
# Runs ON the UNO Q. Stdin secrets contract: 1. sudo password  2. SSID  3. wifi pw
# Result of Arduino's official 5-dsi-touch-a overlay on our 800x480 panel.
unset HISTFILE
IFS= read -r SUDO_PASS; SUDO_PASS=$(printf '%s' "$SUDO_PASS" | tr -d '\r')
IFS= read -r WIFI_SSID
IFS= read -r WIFI_PASS
S() { printf '%s\n' "$SUDO_PASS" | sudo -S -p '' "$@"; }
S true 2>/dev/null || { echo "SUDO PASSWORD REJECTED"; exit 1; }

echo "=== config ==="
arduino-linux-config carrier show 2>&1 | head -6

echo
echo "=== THE RESULT: is there a DRM device at all? ==="
ls /sys/class/drm/
for s in /sys/class/drm/*/status; do
    [ -f "$s" ] && echo "  $(basename "$(dirname "$s")") => $(cat "$s")"
done
for m in /sys/class/drm/*/modes; do
    [ -f "$m" ] && echo "  modes: $(tr '\n' ' ' < "$m")"
done
ls -la /dev/fb0 2>/dev/null || echo "  no /dev/fb0"

echo
echo "=== which drivers bound ==="
lsmod | grep -iE 'waveshare|himax|goodix|jadard|tc358762|panel'

echo
echo "=== the waveshare controller: did it probe this time? ==="
dmesg | grep -iE 'waveshare|regulator-panel|himax|goodix' | head -20

echo
echo "=== attiny driver (ours) - should NOT bind now ==="
dmesg | grep -i 'attiny-dbg' | head -5

echo
echo "=== errors ==="
dmesg | grep -iE 'panel|dsi|drm|regulator' | grep -iE 'err|fail|timeout|-110|-517|deferred' | tail -12

echo
echo "=== backlight ==="
ls /sys/class/backlight/ 2>/dev/null || echo "  none"

echo
echo "=== i2c clients ==="
ls /sys/bus/i2c/devices/ | grep -E '^[0-9]+-[0-9a-f]+$'

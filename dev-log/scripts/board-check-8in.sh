#!/bin/sh
# Runs ON the UNO Q. Stdin secrets contract: 1. sudo password  2. SSID  3. wifi pw
# Full status check with the Waveshare 8-DSI-TOUCH-A attached.
unset HISTFILE
IFS= read -r SUDO_PASS; SUDO_PASS=$(printf '%s' "$SUDO_PASS" | tr -d '\r')
IFS= read -r WIFI_SSID
IFS= read -r WIFI_PASS
S() { printf '%s\n' "$SUDO_PASS" | sudo -S -p '' "$@"; }
S true 2>/dev/null || { echo "SUDO PASSWORD REJECTED"; exit 1; }

echo "=== carrier config ==="
arduino-linux-config carrier show 2>&1 | head -6

echo
echo "=== DRM connectors and modes ==="
ls /sys/class/drm/
for s in /sys/class/drm/*/status; do
    [ -f "$s" ] && echo "  $(basename "$(dirname "$s")") => $(cat "$s")"
done
for m in /sys/class/drm/*/modes; do
    [ -f "$m" ] && echo "  modes: $(tr '\n' ' ' < "$m")"
done
ls -la /dev/dri/ /dev/fb* 2>/dev/null | grep -E 'card|fb'

echo
echo "=== framebuffer ==="
cat /sys/class/graphics/fb0/name 2>/dev/null
cat /sys/class/graphics/fb0/virtual_size 2>/dev/null
cat /sys/class/graphics/fb0/bits_per_pixel 2>/dev/null

echo
echo "=== backlight ==="
for b in /sys/class/backlight/*/; do
    echo "  $b max=$(cat "$b/max_brightness" 2>/dev/null) cur=$(cat "$b/brightness" 2>/dev/null) power=$(cat "$b/bl_power" 2>/dev/null)"
done

echo
echo "=== i2c: did the Goodix touch @0x5d appear this time? ==="
for d in /sys/bus/i2c/devices/i2c-*; do
    n=$(basename "$d" | cut -d- -f2)
    case "$(cat "$d/name" 2>/dev/null)" in
        *CCI*) printf -- "--- bus %s (CCI) ---\n" "$n"; S i2cdetect -y -r "$n" 2>&1 | sed -n '2,9p';;
    esac
done
echo "--- bound clients ---"
ls /sys/bus/i2c/devices/ | grep -E '^[0-9]+-[0-9a-f]+$'

echo
echo "=== touch input devices ==="
grep -iE 'Name=|Handlers=' /proc/bus/input/devices 2>/dev/null

echo
echo "=== the drivers that matter ==="
lsmod | grep -iE 'jadard|waveshare|goodix|panel|tc358762'

echo
echo "=== display dmesg ==="
S dmesg | grep -iE 'jadard|waveshare|goodix|panel|dsi|drm|backlight|regulator-panel' | tail -25

echo
echo "=== errors, if any ==="
S dmesg | grep -iE 'error|fail|timeout|-110|-517' | grep -iE 'panel|dsi|drm|waveshare|goodix|regulator' | tail -10

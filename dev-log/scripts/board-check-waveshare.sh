#!/bin/sh
# Runs ON the UNO Q. Stdin secrets contract: 1. sudo password  2. SSID  3. wifi pw
# Did waveshare-regulator probe this time, on good power?
unset HISTFILE
IFS= read -r SUDO_PASS; SUDO_PASS=$(printf '%s' "$SUDO_PASS" | tr -d '\r')
IFS= read -r WIFI_SSID
IFS= read -r WIFI_PASS
S() { printf '%s\n' "$SUDO_PASS" | sudo -S -p '' "$@"; }
S true 2>/dev/null || { echo "SUDO PASSWORD REJECTED"; exit 1; }

echo "=== THE QUESTION: did waveshare-regulator probe? ==="
S dmesg | grep -iE 'waveshare|attiny|regulator.*0045|0-0045|1-0045' | head -15
echo "--- (a -ETIMEDOUT here means it failed again) ---"

echo
echo "=== backlight devices ==="
ls -la /sys/class/backlight/ 2>/dev/null
BL=$(ls -d /sys/class/backlight/*/ 2>/dev/null | head -1)
[ -n "$BL" ] && echo "  $BL brightness=$(cat "$BL/brightness" 2>/dev/null) power=$(cat "$BL/bl_power" 2>/dev/null)"

echo
echo "=== drm state (panel will be WRONG timings - that is expected) ==="
ls /sys/class/drm/
for s in /sys/class/drm/*/status; do [ -f "$s" ] && echo "  $(basename "$(dirname "$s")") => $(cat "$s")"; done
for m in /sys/class/drm/*/modes; do [ -f "$m" ] && echo "  modes: $(tr '\n' ' ' < "$m")"; done

echo
echo "=== bound i2c clients / gpiochips ==="
ls /sys/bus/i2c/devices/ | grep -E '^[0-9]+-[0-9a-f]+$'
S gpiodetect 2>&1

echo
echo "=== display dmesg ==="
S dmesg | grep -iE 'panel|himax|goodix|dsi|drm|backlight|regulator' | tail -20

if [ -n "$BL" ]; then
    echo
    echo "*** WATCH THE PANEL - backlight blink x4 (2s/2s) ***"
    sleep 3
    i=1
    while [ $i -le 4 ]; do
        S sh -c "echo 0 > $BL/brightness";   sleep 2
        S sh -c "echo 255 > $BL/brightness"; sleep 2
        i=$((i+1))
    done
    echo "left at $(cat "$BL/brightness")"
else
    echo
    echo ">>> no backlight device registered"
fi

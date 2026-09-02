#!/bin/sh
# Runs ON the UNO Q. Stdin secrets contract: 1. sudo password  2. SSID  3. wifi pw
# Post-repower status check.
unset HISTFILE
IFS= read -r SUDO_PASS; SUDO_PASS=$(printf '%s' "$SUDO_PASS" | tr -d '\r')
IFS= read -r WIFI_SSID
IFS= read -r WIFI_PASS
S() { printf '%s\n' "$SUDO_PASS" | sudo -S -p '' "$@"; }

echo "=== uptime / power ==="
uptime
echo "kernel: $(uname -r)"

echo
echo "=== drm connectors ==="
for s in /sys/class/drm/*/status; do
    [ -f "$s" ] && echo "  $(basename "$(dirname "$s")") => $(cat "$s")"
done
for m in /sys/class/drm/*/modes; do
    [ -f "$m" ] && echo "  modes: $(tr '\n' ' ' < "$m")"
done

echo
echo "=== backlight ==="
cat /sys/class/backlight/0-0045/brightness 2>/dev/null
cat /sys/class/backlight/0-0045/bl_power 2>/dev/null

echo
echo "=== tc358762 regulator ==="
for r in /sys/class/regulator/*/; do
    n=$(cat "$r/name" 2>/dev/null)
    case "$n" in *tc358762*) echo "  $n: $(cat "$r/state" 2>/dev/null)";; esac
done

echo
echo "=== ATTINY registers (0x80 ID, 0x81 PORTA, 0x82 PORTB, 0x83 PORTC, 0x86 PWM) ==="
for r in 80 81 82 83 86; do
    printf '  0x%s = %s\n' "$r" "$(S i2cget -f -y 0 0x45 0x$r 2>&1)"
done

echo
echo "=== CCI i2c timeouts this boot ==="
S dmesg | grep -c 'cci.*timeout'

echo
echo "=== display dmesg ==="
S dmesg | grep -iE 'tc358762|attiny|panel|dsi_err|backlight' | tail -12

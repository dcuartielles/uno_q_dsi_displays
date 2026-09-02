#!/bin/sh
# Runs ON the UNO Q. Stdin secrets contract: 1. sudo password  2. SSID  3. wifi pw
#
# Every write in the power-on sequence now returns ret=0. Does the chip's
# register state actually reflect what we wrote?
#   PORTC should be 0x0d  (PC_LED_EN | PC_RST_LCD_N | PC_RST_BRIDGE_N)
#   PORTB should be 0x80  (PB_LCD_MAIN)
#   PORTA should be 0x04  (PA_LCD_LR)
#   PWM   should be 0xff
unset HISTFILE
IFS= read -r SUDO_PASS; SUDO_PASS=$(printf '%s' "$SUDO_PASS" | tr -d '\r')
IFS= read -r WIFI_SSID
IFS= read -r WIFI_PASS
S() { printf '%s\n' "$SUDO_PASS" | sudo -S -p '' "$@"; }
S true 2>/dev/null || { echo "SUDO PASSWORD REJECTED"; exit 1; }

B=$(basename "$(ls -d /sys/bus/i2c/devices/*-0045 2>/dev/null | head -1)" | cut -d- -f1)
echo "bus=$B"

echo
printf '%-8s %-10s %-10s %s\n' REG EXPECTED ACTUAL VERDICT
check() {
    v=$(S i2cget -f -y "$B" 0x45 0x$1 2>&1)
    if [ "$v" = "$2" ]; then r="MATCH"; else r="mismatch"; fi
    printf '0x%-6s %-10s %-10s %s\n' "$1" "$2" "$v" "$r"
}
check 81 0x04
check 82 0x80
check 83 0x0d
check 86 0xff

echo
echo "=== driver's own view (cached port_states via is_enabled) ==="
dmesg | grep -i 'attiny-dbg: is_enabled' | tail -5

echo
echo "=== force a fresh regulator cycle and watch every write ==="
S dmesg -C
BL=$(ls -d /sys/class/backlight/*/ 2>/dev/null | head -1)
S sh -c "echo 0 > $BL/brightness"; sleep 1
S sh -c "echo 255 > $BL/brightness"; sleep 1
dmesg | grep -i attiny-dbg

echo
echo "=== summary ==="
echo "  regulator : $(for r in /sys/class/regulator/*/; do n=$(cat $r/name 2>/dev/null); case $n in *tc358762*) echo "$(cat $r/state)";; esac; done)"
echo "  connector : $(cat /sys/class/drm/card0-DPI-1/status 2>/dev/null)"
echo "  mode      : $(cat /sys/class/drm/card0-DPI-1/modes 2>/dev/null | tr '\n' ' ')"
echo "  backlight : $(cat "$BL/brightness" 2>/dev/null)"
echo "  dsi errors: $(dmesg | grep -c dsi_err)"

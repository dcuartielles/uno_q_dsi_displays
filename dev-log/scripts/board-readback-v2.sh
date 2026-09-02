#!/bin/sh
# Runs ON the UNO Q. Stdin secrets contract: 1. sudo password  2. SSID  3. wifi pw
#
# Every attiny write now returns ret=0. The driver last wrote PORTC=0x0f
# (LED_EN|RST_TP_N|RST_LCD_N|RST_BRIDGE_N) and PORTB=0x80, PORTA=0x04, PWM=0xff.
# Do the registers reflect that? If not, the chip is ACKing and discarding -
# which would mean it is not an RPi ATTINY at all, regardless of driver.
unset HISTFILE
IFS= read -r SUDO_PASS; SUDO_PASS=$(printf '%s' "$SUDO_PASS" | tr -d '\r')
IFS= read -r WIFI_SSID
IFS= read -r WIFI_PASS
S() { printf '%s\n' "$SUDO_PASS" | sudo -S -p '' "$@"; }
S true 2>/dev/null || { echo "SUDO PASSWORD REJECTED"; exit 1; }

B=$(basename "$(ls -d /sys/bus/i2c/devices/*-0045 2>/dev/null | head -1)" | cut -d- -f1)
echo "bus=$B"

echo
printf '%-8s %-12s %-10s %s\n' REG "DRIVER WROTE" ACTUAL VERDICT
chk() {
    v=$(S i2cget -f -y "$B" 0x45 0x$1 2>&1)
    [ "$v" = "$2" ] && r=MATCH || r=mismatch
    printf '0x%-6s %-12s %-10s %s\n' "$1" "$2" "$v" "$r"
}
chk 80 0xc3
chk 81 0x04
chk 82 0x80
chk 83 0x0f
chk 86 0xff

echo
echo "=== does the DSI link show errors? (8-inch panel had ZERO) ==="
dmesg | grep -c dsi_err
dmesg | grep dsi_err | tail -3

echo
echo "=== bridge: is the tc358762 responding over DSI at all? ==="
echo "  (tc358762 writes are DSI generic writes; failures show as DSI errors)"
dmesg | grep -iE 'tc358762|mipi_dsi|dsi.*err' | tail -8

echo
echo "=== connector / mode actually being driven ==="
S modetest -M msm -c 2>/dev/null | head -12

echo
echo "=== is a CRTC live and scanning out? ==="
S cat /sys/kernel/debug/dri/0/state 2>/dev/null | grep -E 'crtc|enable=|active=|fb=|format=' | head -12

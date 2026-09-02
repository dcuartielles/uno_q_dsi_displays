#!/bin/sh
# Runs ON the UNO Q. Stdin secrets contract: 1. sudo password  2. SSID  3. wifi pw
#
# Independent check on whether the PANEL's 3V3 rail is really healthy.
#
# The device at 0x38 is a second chip on the panel, separate from the ATTINY and
# with its own supply. If it returns plausible ID registers, the panel is properly
# powered and we can stop chasing power entirely.
#
# FT5x06-family ID registers (8-bit addressing):
#   0xA3 chip id (0x55=FT5x06, 0x06/0x08/0x64 variants)
#   0xA6 firmware version   0xA8 vendor id (0x51 etc)   0xA1 lib version
unset HISTFILE
IFS= read -r SUDO_PASS; SUDO_PASS=$(printf '%s' "$SUDO_PASS" | tr -d '\r')
IFS= read -r WIFI_SSID
IFS= read -r WIFI_PASS
S() { printf '%s\n' "$SUDO_PASS" | sudo -S -p '' "$@"; }
S true 2>/dev/null || { echo "SUDO PASSWORD REJECTED"; exit 1; }

B=$(basename "$(ls -d /sys/bus/i2c/devices/*-0045 2>/dev/null | head -1)" | cut -d- -f1)
echo "attiny/touch bus = $B"

echo
echo "=== touch controller @0x38 : ID registers ==="
for r in A1 A3 A6 A8 A9 00 01 02; do
    printf '  0x%s = %s\n' "$r" "$(S i2cget -f -y "$B" 0x38 0x$r 2>&1)"
done

echo
echo "=== a block read of the touch report area (0x00-0x0f) ==="
S i2cdump -f -y -r 0x00-0x0f "$B" 0x38 b 2>&1 | head -6

echo
echo "=== ATTINY @0x45 for comparison ==="
for r in 80 81 82 83 85 86; do
    printf '  0x%s = %s\n' "$r" "$(S i2cget -f -y "$B" 0x45 0x$r 2>&1)"
done

echo
echo "=== PCA9555 @0x26 (carrier side, known-good reference) ==="
for r in 00 01 02 03; do
    printf '  0x%s = %s\n' "$r" "$(S i2cget -f -y "$B" 0x26 0x$r 2>&1)"
done

echo
echo "=== interpretation hint ==="
echo "  touch returning varied, plausible values  -> panel 3V3 is HEALTHY"
echo "  touch returning all 0xff / errors         -> panel side under-powered"

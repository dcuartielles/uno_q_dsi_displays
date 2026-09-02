#!/bin/sh
# Runs ON the UNO Q. Stdin secrets contract: 1. sudo password  2. SSID  3. wifi pw
#
# What transaction types does the Qualcomm CCI adapter actually support?
# I2C_RDWR (combined write+repeated-START+read) returned ENOTSUP from userspace.
# The FT5x06 needs a burst read; if the adapter cannot do combined transactions,
# that is a hard constraint, not a driver bug.
unset HISTFILE
IFS= read -r SUDO_PASS; SUDO_PASS=$(printf '%s' "$SUDO_PASS" | tr -d '\r')
IFS= read -r WIFI_SSID
IFS= read -r WIFI_PASS
S() { printf '%s\n' "$SUDO_PASS" | sudo -S -p '' "$@"; }
S true 2>/dev/null || { echo "SUDO PASSWORD REJECTED"; exit 1; }

B=$(basename "$(ls -d /sys/bus/i2c/devices/*-0045 2>/dev/null | head -1)" | cut -d- -f1)
echo "=== adapter functionality, bus $B (CCI) ==="
S i2cdetect -F "$B" 2>&1

echo
echo "=== for comparison, a Geni-I2C bus ==="
for d in /sys/bus/i2c/devices/i2c-*; do
    n=$(basename "$d" | cut -d- -f2)
    case "$(cat "$d/name" 2>/dev/null)" in
        *Geni*) echo "--- bus $n (Geni) ---"; S i2cdetect -F "$n" 2>&1 | head -14; break;;
    esac
done

echo
echo "=== i2ctransfer (uses I2C_RDWR) against the touch chip ==="
S i2ctransfer -f -y "$B" w1@0x38 0x00 r8 2>&1

echo
echo "=== i2cdump of the touch chip, byte mode ==="
S i2cdump -f -y -r 0x00-0x10 "$B" 0x38 b 2>&1 | head -6

echo
echo "=== how does the kernel's edt_ft5x06 read? (regmap bulk) ==="
echo "  it uses regmap_bulk_read, which needs I2C_FUNC_I2C on the adapter."
echo "  If that flag is missing above, the mainline touch driver cannot work"
echo "  on this bus regardless of the IRQ question."

echo
echo "=== but the 8-inch panel's Goodix DID work on this same bus ==="
echo "  goodix_ts also does multi-byte reads, so compare carefully."

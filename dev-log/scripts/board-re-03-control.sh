#!/bin/sh
# Runs ON the UNO Q. Stdin secrets contract: 1. sudo password  2. SSID  3. wifi pw
#
# REVERSE ENGINEERING, STEP 3: control experiment.
#
# The chip ACKed writes to every register of three different protocols. Before
# concluding anything from that, check whether this bus reports NAKs at all:
# write to I2C addresses where NOTHING exists. If those also "succeed", then
# every write-success result we have is meaningless.
unset HISTFILE
IFS= read -r SUDO_PASS; SUDO_PASS=$(printf '%s' "$SUDO_PASS" | tr -d '\r')
IFS= read -r WIFI_SSID
IFS= read -r WIFI_PASS
S() { printf '%s\n' "$SUDO_PASS" | sudo -S -p '' "$@"; }
S true 2>/dev/null || { echo "SUDO PASSWORD REJECTED"; exit 1; }

B=$(basename "$(ls -d /sys/bus/i2c/devices/*-0045 2>/dev/null | head -1)" | cut -d- -f1)
echo "bus=$B"

echo
echo "=== what is actually present on this bus ==="
S i2cdetect -y -r "$B" 2>&1 | sed -n '2,9p'

echo
echo "=== CONTROL: write to addresses where NOTHING exists ==="
for a in 0x10 0x22 0x44 0x46 0x55 0x60 0x70; do
    if S i2cset -f -y "$B" $a 0x00 0x00 >/dev/null 2>&1; then
        printf '  write to %s : "ok"   <-- BOGUS, nothing is there\n' "$a"
    else
        printf '  write to %s : failed (correct)\n' "$a"
    fi
done

echo
echo "=== CONTROL: read from addresses where NOTHING exists ==="
for a in 0x10 0x44 0x46 0x60; do
    v=$(S i2cget -f -y "$B" $a 0x00 2>&1)
    printf '  read %s -> %s\n' "$a" "$v"
done

echo
echo "=== for comparison: the real devices ==="
printf '  0x26 pca9555 read 0x00 -> %s\n' "$(S i2cget -f -y $B 0x26 0x00 2>&1)"
printf '  0x38 touch   read 0xA3 -> %s\n' "$(S i2cget -f -y $B 0x38 0xA3 2>&1)"
printf '  0x45 panel   read 0x80 -> %s\n' "$(S i2cget -f -y $B 0x45 0x80 2>&1)"

echo
echo "=== does 0x45 NAK a write to an out-of-range register? ==="
for r in 0x00 0x7f 0xfe 0xff; do
    if S i2cset -f -y "$B" 0x45 $r 0x00 >/dev/null 2>&1; then
        printf '  0x45 reg %s write : ok\n' "$r"
    else
        printf '  0x45 reg %s write : failed\n' "$r"
    fi
done

echo
echo "=== interpretation ==="
echo "  If the bogus addresses also report ok, writes tell us nothing and every"
echo "  'ret=0 / ok' result in this investigation needs re-reading."

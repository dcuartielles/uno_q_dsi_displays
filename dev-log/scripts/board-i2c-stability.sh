#!/bin/sh
# Runs ON the UNO Q. Stdin secrets contract: 1. sudo password  2. SSID  3. wifi pw
#
# Is the panel's I2C intermittent? Measure read and write success rates right
# now, and compare against the PCA9555 on the same bus as a control.
unset HISTFILE
IFS= read -r SUDO_PASS; SUDO_PASS=$(printf '%s' "$SUDO_PASS" | tr -d '\r')
IFS= read -r WIFI_SSID
IFS= read -r WIFI_PASS
S() { printf '%s\n' "$SUDO_PASS" | sudo -S -p '' "$@"; }
S true 2>/dev/null || { echo "SUDO PASSWORD REJECTED"; exit 1; }

B=$(basename "$(ls -d /sys/bus/i2c/devices/*-0045 2>/dev/null | head -1)" | cut -d- -f1)
echo "bus=$B   (uptime $(cut -d. -f1 /proc/uptime)s)"

echo
echo "=== panel controller @0x45 : 50 reads ==="
ok=0; bad=0; i=1
while [ $i -le 50 ]; do
    [ "$(S i2cget -f -y $B 0x45 0x80 2>/dev/null)" = "0xc3" ] && ok=$((ok+1)) || bad=$((bad+1))
    i=$((i+1))
done
echo "  reads : $ok ok, $bad failed"

echo "=== panel controller @0x45 : 50 writes ==="
wok=0; wbad=0; i=1
while [ $i -le 50 ]; do
    S i2cset -f -y $B 0x45 0x86 0xff >/dev/null 2>&1 && wok=$((wok+1)) || wbad=$((wbad+1))
    i=$((i+1))
done
echo "  writes: $wok ok, $wbad failed"

echo
echo "=== CONTROL: pca9555 @0x26 on the SAME bus : 50 reads + 50 writes ==="
pok=0; pbad=0; i=1
while [ $i -le 50 ]; do
    S i2cget -f -y $B 0x26 0x00 >/dev/null 2>&1 && pok=$((pok+1)) || pbad=$((pbad+1))
    i=$((i+1))
done
echo "  reads : $pok ok, $pbad failed"
cok=0; cbad=0; i=1
while [ $i -le 50 ]; do
    S i2cset -f -y $B 0x26 0x06 0xff >/dev/null 2>&1 && cok=$((cok+1)) || cbad=$((cbad+1))
    i=$((i+1))
done
echo "  writes: $cok ok, $cbad failed"

echo
echo "=== CCI controller timeouts this boot ==="
dmesg | grep -c 'cci.*timeout'

echo
echo "=== interpretation ==="
echo "  panel fails while pca9555 succeeds -> fault is the panel/cable, not the bus"
echo "  both fine now but failed at boot    -> intermittent contact or marginal signal"

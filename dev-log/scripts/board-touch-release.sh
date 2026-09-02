#!/bin/sh
# Runs ON the UNO Q. Stdin secrets contract: 1. sudo password  2. SSID  3. wifi pw
#
# The touch controller has been held in reset: PORTC=0x0f (which sets
# PC_RST_TP_N) failed with -110 during boot. The ATTINY is responsive now, so
# release the touch reset by hand, wait RPi's 300ms reset-deassert delay, then
# poll the digitiser.
unset HISTFILE
IFS= read -r SUDO_PASS; SUDO_PASS=$(printf '%s' "$SUDO_PASS" | tr -d '\r')
IFS= read -r WIFI_SSID
IFS= read -r WIFI_PASS
S() { printf '%s\n' "$SUDO_PASS" | sudo -S -p '' "$@"; }
S true 2>/dev/null || { echo "SUDO PASSWORD REJECTED"; exit 1; }

B=$(basename "$(ls -d /sys/bus/i2c/devices/*-0045 2>/dev/null | head -1)" | cut -d- -f1)
echo "i2c bus = $B"

echo
echo "=== 1. toggle the touch reset: PORTC 0x0d (TP in reset) -> 0x0f (released) ==="
i=1
while [ $i -le 20 ]; do
    if S i2cset -f -y "$B" 0x45 0x83 0x0d >/dev/null 2>&1; then echo "  assert  TP reset  ok (try $i)"; break; fi
    i=$((i+1)); sleep 0.2
done
sleep 1
i=1
while [ $i -le 20 ]; do
    if S i2cset -f -y "$B" 0x45 0x83 0x0f >/dev/null 2>&1; then echo "  release TP reset  ok (try $i)"; break; fi
    i=$((i+1)); sleep 0.2
done

echo "  waiting 500ms (RPi uses RESET_DELAY_MS=300 from deassert to I2C)"
sleep 1

echo
echo "=== 2. touch chip registers after reset release ==="
for r in 00 01 02 A3 A6 A8; do
    printf '  0x%s = %s\n' "$r" "$(S i2cget -f -y "$B" 0x38 0x$r 2>&1)"
done

echo
echo "*** 3. TOUCH AND DRAG ON THE PANEL FOR 30 SECONDS ***"
echo
S python3 /tmp/touchpoll2.py "$B" 30

#!/bin/sh
# Runs ON the UNO Q. Stdin secrets contract: 1. sudo password  2. SSID  3. wifi pw
# Capture REAL touch events (not evtest's capability header).
unset HISTFILE
IFS= read -r SUDO_PASS; SUDO_PASS=$(printf '%s' "$SUDO_PASS" | tr -d '\r')
IFS= read -r WIFI_SSID
IFS= read -r WIFI_PASS
S() { printf '%s\n' "$SUDO_PASS" | sudo -S -p '' "$@"; }
S true 2>/dev/null || { echo "SUDO PASSWORD REJECTED"; exit 1; }

DEV=/dev/input/event2

echo "*** TOUCH AND DRAG ON THE SCREEN NOW - capturing for 15 seconds ***"
echo
S timeout 15 evtest "$DEV" 2>/dev/null > /tmp/touch.log
# real events all start with "Event: time"
n=$(grep -c '^Event: time' /tmp/touch.log)
echo "captured $n input events"
echo
echo "--- first 25 real events ---"
grep '^Event: time' /tmp/touch.log | head -25

echo
echo "--- distinct coordinates seen ---"
grep -E 'ABS_MT_POSITION_(X|Y)' /tmp/touch.log | grep '^Event: time' | \
    sed 's/.*(\(ABS_MT_POSITION_[XY]\)), value \([0-9]*\)/\1=\2/' | sort -u | head -20

echo
echo "=== goodix errors during the test ==="
S dmesg | grep -i goodix | tail -4

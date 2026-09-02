#!/bin/sh
# Runs ON the UNO Q. Stdin secrets contract: 1. sudo password  2. SSID  3. wifi pw
# Does the touchscreen actually report events?
unset HISTFILE
IFS= read -r SUDO_PASS; SUDO_PASS=$(printf '%s' "$SUDO_PASS" | tr -d '\r')
IFS= read -r WIFI_SSID
IFS= read -r WIFI_PASS
S() { printf '%s\n' "$SUDO_PASS" | sudo -S -p '' "$@"; }
S true 2>/dev/null || { echo "SUDO PASSWORD REJECTED"; exit 1; }

DEV=$(grep -B5 'Goodix' /proc/bus/input/devices | grep -o 'event[0-9]*' | head -1)
[ -z "$DEV" ] && DEV=$(grep -A5 'Goodix' /proc/bus/input/devices | grep -o 'event[0-9]*' | head -1)
echo "touch device: /dev/input/$DEV"

command -v evtest >/dev/null 2>&1 || {
    echo "installing evtest ..."
    S env DEBIAN_FRONTEND=noninteractive apt-get -y install evtest 2>&1 | tail -2
}

echo
echo "=== device capabilities ==="
S evtest --info "/dev/input/$DEV" 2>&1 | head -30

echo
echo "*** TOUCH AND DRAG A FINGER ON THE SCREEN FOR THE NEXT 15 SECONDS ***"
echo
S timeout 15 evtest "/dev/input/$DEV" 2>&1 | grep -E 'ABS_MT_POSITION|BTN_TOUCH|ABS_X|ABS_Y' | head -30
echo
echo "=== any touch i2c errors during that? ==="
S dmesg | grep -i 'goodix' | tail -5

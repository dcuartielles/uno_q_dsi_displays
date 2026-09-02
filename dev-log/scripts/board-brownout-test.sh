#!/bin/sh
# Runs ON the UNO Q. Stdin secrets contract: 1. sudo password  2. SSID  3. wifi pw
#
# BROWNOUT TEST - run this with a multimeter on the panel's 3V3.
#
# Probe: panel FPC pin 15 (or 14) = 3V3, against any GND pin (1/4/7/10/13/16/19),
# or any 3V3 test point on the panel PCB.
#
# The loop alternates 10s backlight OFF / 10s backlight ON, five times, and
# reads the controller's registers in each state.
#
#   3V3 steady at ~3.3 V in both states  -> power is fine, controller is at fault
#   3V3 sags when the backlight is ON    -> the DSI connector cannot supply the
#                                            ~360 mA this panel needs
unset HISTFILE
IFS= read -r SUDO_PASS; SUDO_PASS=$(printf '%s' "$SUDO_PASS" | tr -d '\r')
IFS= read -r WIFI_SSID
IFS= read -r WIFI_PASS
S() { printf '%s\n' "$SUDO_PASS" | sudo -S -p '' "$@"; }
S true 2>/dev/null || { echo "SUDO PASSWORD REJECTED"; exit 1; }

B=$(basename "$(ls -d /sys/bus/i2c/devices/*-0045 2>/dev/null | head -1)" | cut -d- -f1)
BL=$(ls -d /sys/class/backlight/*/ 2>/dev/null | head -1)
echo "bus=$B backlight=$BL"

regs() {
    printf '    regs: 0x80=%s 0x81=%s 0x82=%s 0x83=%s 0x86=%s\n' \
        "$(S i2cget -f -y $B 0x45 0x80 2>&1)" \
        "$(S i2cget -f -y $B 0x45 0x81 2>&1)" \
        "$(S i2cget -f -y $B 0x45 0x82 2>&1)" \
        "$(S i2cget -f -y $B 0x45 0x83 2>&1)" \
        "$(S i2cget -f -y $B 0x45 0x86 2>&1)"
}

echo
echo "*** PUT THE METER ON THE PANEL'S 3V3 NOW - starting in 8 seconds ***"
echo "*** 5 cycles of: 10s backlight OFF, then 10s backlight ON        ***"
sleep 8

i=1
while [ $i -le 5 ]; do
    echo "cycle $i: BACKLIGHT OFF (expect steady 3.3 V)"
    S sh -c "echo 0 > $BL/brightness"
    sleep 2; regs; sleep 8

    echo "cycle $i: BACKLIGHT ON  (watch for a sag)"
    S sh -c "echo 255 > $BL/brightness"
    sleep 2; regs; sleep 8
    i=$((i + 1))
done

S sh -c "echo 255 > $BL/brightness"
echo
echo "done - backlight left ON"

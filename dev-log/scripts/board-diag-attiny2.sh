#!/bin/sh
# Runs ON the UNO Q. Stdin secrets contract: 1. sudo password  2. SSID  3. wifi pw
# Why does the ATTINY time out (-110) during drm_panel_enable?
unset HISTFILE

IFS= read -r SUDO_PASS; SUDO_PASS=$(printf '%s' "$SUDO_PASS" | tr -d '\r')
IFS= read -r WIFI_SSID
IFS= read -r WIFI_PASS

S() { printf '%s\n' "$SUDO_PASS" | sudo -S -p '' "$@"; }
S true 2>/dev/null || { echo "SUDO PASSWORD REJECTED"; exit 1; }

echo "=== full enable() and backlight update_status() ==="
sed -n '94,200p' "$HOME/panel-build/rpi-panel-attiny-regulator.c"

echo
echo "=== full dmesg, display section ==="
S dmesg | grep -iE "tc358762|attiny|panel|dsi|drm|i2c|cci" | tail -30

echo
echo "=== live ATTINY registers ==="
for r in 80 81 82 83 85 86; do
    printf '  0x%s = %s\n' "$r" "$(S i2cget -f -y 0 0x45 0x$r 2>&1)"
done

echo
echo "=== can the backlight still be driven via sysfs right now? ==="
S sh -c 'echo 0 > /sys/class/backlight/0-0045/brightness' 2>&1 && echo "write 0 OK" || echo "write 0 FAILED"
sleep 1
S sh -c 'echo 255 > /sys/class/backlight/0-0045/brightness' 2>&1 && echo "write 255 OK" || echo "write 255 FAILED"
cat /sys/class/backlight/0-0045/brightness

echo
echo "=== i2c bus speed configured for cci_i2c0 ==="
S dtc -I dtb -O dts /boot/efi/dtb/qcom/qrb2210-arduino-imola.dtb 2>/dev/null | grep -n -A3 "5c1b000\|cci@" | grep -i "clock-frequency" | head -5

echo
echo "=== rescan the bus (is 0x45 still answering?) ==="
S i2cdetect -y -r 0 2>&1 | head -8

#!/bin/sh
# Runs ON the UNO Q. Stdin secrets contract: 1. sudo password  2. SSID  3. wifi pw
# Do WRITES work at all on the Qualcomm CCI i2c-0 bus, or only reads?
unset HISTFILE

IFS= read -r SUDO_PASS; SUDO_PASS=$(printf '%s' "$SUDO_PASS" | tr -d '\r')
IFS= read -r WIFI_SSID
IFS= read -r WIFI_PASS

S() { printf '%s\n' "$SUDO_PASS" | sudo -S -p '' "$@"; }
S true 2>/dev/null || { echo "SUDO PASSWORD REJECTED"; exit 1; }

echo "=== 1. are reads stable and meaningful? (REG_ID x5) ==="
i=1; while [ $i -le 5 ]; do printf '  read %d: %s\n' "$i" "$(S i2cget -f -y 0 0x45 0x80 2>&1)"; i=$((i+1)); done

echo
echo "=== 2. controlled write test on REG_PWM (0x86) ==="
echo "  before: $(S i2cget -f -y 0 0x45 0x86 2>&1)"
echo "  writing 0x00 ..."
S i2cset -f -y 0 0x45 0x86 0x00 2>&1; echo "  exit=$?"
echo "  after : $(S i2cget -f -y 0 0x45 0x86 2>&1)"
echo "  writing 0x7f ..."
S i2cset -f -y 0 0x45 0x86 0x7f 2>&1; echo "  exit=$?"
echo "  after : $(S i2cget -f -y 0 0x45 0x86 2>&1)"

echo
echo "=== 3. do writes work on the OTHER device on this bus (pca9555 @0x26)? ==="
echo "  carrier LEDs exposed?"
ls /sys/class/leds/ 2>/dev/null
for l in /sys/class/leds/*/; do
    case "$l" in *carrier*|*media*|*user*)
        echo "  toggling $l"
        S sh -c "echo 255 > $l/brightness" 2>&1 && echo "   on OK" || echo "   on FAILED"
        sleep 1
        S sh -c "echo 0 > $l/brightness" 2>&1 && echo "   off OK" || echo "   off FAILED"
        ;;
    esac
done

echo
echo "=== 4. gpio chips present (pca9555 + attiny) ==="
S gpiodetect 2>/dev/null || cat /sys/kernel/debug/gpio 2>/dev/null | head -30

echo
echo "=== 5. fresh CCI timeout count since boot ==="
S dmesg | grep -c "cci.*timeout"
echo "  last 3:"
S dmesg | grep "cci.*timeout" | tail -3

echo
echo "=== 6. is the camera/CCI power domain actually on? ==="
S cat /sys/kernel/debug/pm_genpd/pm_genpd_summary 2>/dev/null | head -25

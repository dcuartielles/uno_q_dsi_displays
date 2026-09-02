#!/bin/sh
# Runs ON the UNO Q. Stdin secrets contract: 1. sudo password  2. SSID  3. wifi pw
#
# Live test: read the ATTINY panel controller's registers, then manually
# release the TC358762 bridge reset, to confirm that "bridge held in reset"
# is why the panel is dark. Reversible, no reboot.
#
#   REG_ID    0x80    (0xde = ver1, 0xc3 = ver2)
#   REG_PORTA 0x81    PA_LCD_LR = BIT(2)
#   REG_PORTB 0x82    PB_BRIDGE_PWRDNX_N=BIT(0) PB_LCD_VCC_N=BIT(1) PB_LCD_MAIN=BIT(7)
#   REG_PORTC 0x83    PC_LED_EN=BIT(0) PC_RST_TP_N=BIT(1) PC_RST_LCD_N=BIT(2) PC_RST_BRIDGE_N=BIT(3)
#   REG_PWM   0x86
unset HISTFILE

IFS= read -r SUDO_PASS; SUDO_PASS=$(printf '%s' "$SUDO_PASS" | tr -d '\r')
IFS= read -r WIFI_SSID
IFS= read -r WIFI_PASS

S() { printf '%s\n' "$SUDO_PASS" | sudo -S -p '' "$@"; }
S true 2>/dev/null || { echo "SUDO PASSWORD REJECTED"; exit 1; }

rd() { printf '  %-12s (0x%s) = 0x%s\n' "$2" "$1" "$(S i2cget -f -y 0 0x45 0x$1 2>/dev/null | sed 's/0x//')"; }

echo "=== current ATTINY register state ==="
rd 80 REG_ID
rd 81 REG_PORTA
rd 82 REG_PORTB
rd 83 REG_PORTC
rd 86 REG_PWM

echo
echo "interpretation:"
PC=$(S i2cget -f -y 0 0x45 0x83 2>/dev/null)
PB=$(S i2cget -f -y 0 0x45 0x82 2>/dev/null)
echo "  PORTB=$PB  PORTC=$PC"
echo "  (PORTC bit3 = RST_BRIDGE_N: 0 means the TC358762 is HELD IN RESET)"
echo "  (PORTB bit7 = LCD_MAIN: 1 means panel main rail is ON)"

echo
echo "=== bringing the panel up by hand ==="
echo "1. panel power: PORTB = 0x80 (LCD_MAIN on, LCD_VCC_N low)"
S i2cset -f -y 0 0x45 0x82 0x80
sleep 1
echo "2. orientation: PORTA = 0x04 (PA_LCD_LR)"
S i2cset -f -y 0 0x45 0x81 0x04
sleep 1
echo "3. release resets + LED enable: PORTC = 0x0f"
echo "   (LED_EN | RST_TP_N | RST_LCD_N | RST_BRIDGE_N)"
S i2cset -f -y 0 0x45 0x83 0x0f
sleep 1
echo "4. backlight PWM to full: REG_PWM = 0xff"
S i2cset -f -y 0 0x45 0x86 0xff
sleep 1

echo
echo "=== register state after ==="
rd 81 REG_PORTA
rd 82 REG_PORTB
rd 83 REG_PORTC
rd 86 REG_PWM

echo
echo "=== regulator now reports ==="
for r in /sys/class/regulator/*/; do
    n=$(cat "$r/name" 2>/dev/null)
    case "$n" in *tc358762*) echo "$n: state=$(cat "$r/state" 2>/dev/null)";; esac
done

echo
echo "=== repaint the framebuffer (solid green) ==="
python3 -c "
w,h=800,480
open('/dev/fb0','wb').write(bytes([0,255,0,255])*(w*h))
print('painted GREEN')
" 2>&1

echo
echo "*** LOOK AT THE SCREEN NOW ***"

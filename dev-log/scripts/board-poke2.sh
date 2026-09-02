#!/bin/sh
# Runs ON the UNO Q. Stdin secrets contract: 1. sudo password  2. SSID  3. wifi pw
#
# With proper power, do ATTINY register writes now STICK? Previously (on PC USB
# power) every write was ACKed and ignored. This decides whether the register
# readback is meaningful, and whether PC_LED_EN (the backlight LED enable) is
# actually set.
#
#   REG_PORTC 0x83: PC_LED_EN=bit0  PC_RST_TP_N=bit1  PC_RST_LCD_N=bit2  PC_RST_BRIDGE_N=bit3
#   REG_PWM   0x86
unset HISTFILE
IFS= read -r SUDO_PASS; SUDO_PASS=$(printf '%s' "$SUDO_PASS" | tr -d '\r')
IFS= read -r WIFI_SSID
IFS= read -r WIFI_PASS
S() { printf '%s\n' "$SUDO_PASS" | sudo -S -p '' "$@"; }
S true 2>/dev/null || { echo "SUDO PASSWORD REJECTED"; exit 1; }

rd() { S i2cget -f -y 0 0x45 0x$1 2>&1; }

echo "=== before ==="
for r in 80 81 82 83 85 86; do printf '  0x%s = %s\n' "$r" "$(rd $r)"; done

echo
echo "=== write REG_PWM (0x86) = 0x00, read back ==="
S i2cset -f -y 0 0x45 0x86 0x00; echo "  exit=$?  -> 0x86 = $(rd 86)"
echo "=== write REG_PWM (0x86) = 0xff, read back ==="
S i2cset -f -y 0 0x45 0x86 0xff; echo "  exit=$?  -> 0x86 = $(rd 86)"

echo
echo "=== write REG_PORTC (0x83) = 0x0f  (LED_EN|RST_TP_N|RST_LCD_N|RST_BRIDGE_N) ==="
S i2cset -f -y 0 0x45 0x83 0x0f; echo "  exit=$?  -> 0x83 = $(rd 83)"

echo
echo "=== write REG_POWERON (0x85) = 0x01 ==="
S i2cset -f -y 0 0x45 0x85 0x01; echo "  exit=$?  -> 0x85 = $(rd 85)"

echo
echo "*** LOOK AT THE PANEL for 15 seconds - toggling LED_EN via PORTC ***"
i=1
while [ $i -le 5 ]; do
    S i2cset -f -y 0 0x45 0x83 0x0e   # LED_EN cleared
    sleep 1.5
    S i2cset -f -y 0 0x45 0x83 0x0f   # LED_EN set
    sleep 1.5
    i=$((i+1))
done

echo
echo "=== after ==="
for r in 81 82 83 85 86; do printf '  0x%s = %s\n' "$r" "$(rd $r)"; done

echo
echo "=== repaint colour bars ==="
python3 -c "
W,H=800,480
bars=[(255,255,255),(0,255,255),(255,255,0),(0,255,0),(255,0,255),(0,0,255),(255,0,0),(0,0,0)]
row=b''
for x in range(W):
    b,g,r=bars[min(x*len(bars)//W,len(bars)-1)]
    row+=bytes([b,g,r,255])
open('/dev/fb0','wb').write(row*H)
print('bars painted')
"

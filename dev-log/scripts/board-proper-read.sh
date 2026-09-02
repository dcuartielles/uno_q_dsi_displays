#!/bin/sh
# Runs ON the UNO Q. Stdin secrets contract: 1. sudo password  2. SSID  3. wifi pw
#
# Read the ATTINY the way its own driver does: register address as a SEPARATE
# write transaction, ~5 ms delay, then a SEPARATE read. i2cget's combined
# repeated-START read is the wrong protocol for this chip, so every readback
# so far may have been garbage.
unset HISTFILE
IFS= read -r SUDO_PASS; SUDO_PASS=$(printf '%s' "$SUDO_PASS" | tr -d '\r')
IFS= read -r WIFI_SSID
IFS= read -r WIFI_PASS
S() { printf '%s\n' "$SUDO_PASS" | sudo -S -p '' "$@"; }
S true 2>/dev/null || { echo "SUDO PASSWORD REJECTED"; exit 1; }

B=$(basename "$(ls -d /sys/bus/i2c/devices/*-0045 2>/dev/null | head -1)" | cut -d- -f1)
echo "bus=$B"

# proper split read: write reg (stop), delay, read (stop)
pread() {
    S i2ctransfer -f -y "$B" w1@0x45 0x$1 >/dev/null 2>&1
    sleep 0.02
    S i2ctransfer -f -y "$B" r1@0x45 2>&1
}

echo
echo "=== SPLIT reads (driver's protocol) vs COMBINED reads (i2cget) ==="
printf '%-6s %-10s %-10s\n' REG SPLIT COMBINED
for r in 80 81 82 83 85 86; do
    printf '0x%-4s %-10s %-10s\n' "$r" "$(pread $r)" "$(S i2cget -f -y $B 0x45 0x$r 2>&1)"
done

echo
echo "=== now WRITE and re-read with the correct protocol ==="
echo "-- write REG_PWM(0x86)=0x00 --"
S i2ctransfer -f -y "$B" w2@0x45 0x86 0x00 2>&1; echo "   exit=$?"
sleep 0.05
echo "   split read 0x86 = $(pread 86)"

echo "-- write REG_PWM(0x86)=0x7f --"
S i2ctransfer -f -y "$B" w2@0x45 0x86 0x7f 2>&1; echo "   exit=$?"
sleep 0.05
echo "   split read 0x86 = $(pread 86)"

echo "-- write REG_PORTC(0x83)=0x0f --"
S i2ctransfer -f -y "$B" w2@0x45 0x83 0x0f 2>&1; echo "   exit=$?"
sleep 0.05
echo "   split read 0x83 = $(pread 83)"

echo
echo "*** WATCH THE PANEL: full power-on sequence, driver's exact order ***"
sleep 3
echo "  PORTC=0x00 (resets asserted)"; S i2ctransfer -f -y "$B" w2@0x45 0x83 0x00 >/dev/null 2>&1; sleep 1
echo "  PORTA=0x04 (PA_LCD_LR)";       S i2ctransfer -f -y "$B" w2@0x45 0x81 0x04 >/dev/null 2>&1; sleep 1
echo "  PORTB=0x80 (LCD_MAIN)";        S i2ctransfer -f -y "$B" w2@0x45 0x82 0x80 >/dev/null 2>&1; sleep 1
echo "  PORTC=0x01 (LED_EN)";          S i2ctransfer -f -y "$B" w2@0x45 0x83 0x01 >/dev/null 2>&1; sleep 1
echo "  PORTC=0x0d (LED_EN|RST_LCD_N|RST_BRIDGE_N)"
S i2ctransfer -f -y "$B" w2@0x45 0x83 0x0d >/dev/null 2>&1; sleep 1
echo "  PWM=0xff";                     S i2ctransfer -f -y "$B" w2@0x45 0x86 0xff >/dev/null 2>&1
sleep 8

echo
echo "=== read back the whole port set with the correct protocol ==="
for r in 81 82 83 85 86; do printf '  0x%s = %s\n' "$r" "$(pread $r)"; done

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

#!/bin/sh
# Runs ON the UNO Q. Stdin secrets contract: 1. sudo password  2. SSID  3. wifi pw
#
# Part 1: how reliable is the I2C link to the ATTINY, really?
# Part 2: sweep the known panel power-on sequences, 10s each, announced,
#         so the user can report WHICH phase (if any) lights the panel.
unset HISTFILE
IFS= read -r SUDO_PASS; SUDO_PASS=$(printf '%s' "$SUDO_PASS" | tr -d '\r')
IFS= read -r WIFI_SSID
IFS= read -r WIFI_PASS
S() { printf '%s\n' "$SUDO_PASS" | sudo -S -p '' "$@"; }
S true 2>/dev/null || { echo "SUDO PASSWORD REJECTED"; exit 1; }

echo "=============================================="
echo " PART 1 - I2C reliability to ATTINY @0x45"
echo "=============================================="
ok=0; bad=0; i=1
while [ $i -le 40 ]; do
    v=$(S i2cget -f -y 0 0x45 0x80 2>/dev/null)
    if [ "$v" = "0xc3" ]; then ok=$((ok+1)); else bad=$((bad+1)); fi
    i=$((i+1))
done
echo "  reads of REG_ID:  $ok correct, $bad wrong/failed (of 40)"

wok=0; wbad=0; i=1
while [ $i -le 40 ]; do
    if S i2cset -f -y 0 0x45 0x86 0xff >/dev/null 2>&1; then wok=$((wok+1)); else wbad=$((wbad+1)); fi
    i=$((i+1))
done
echo "  writes to REG_PWM: $wok ok, $wbad failed (of 40)"

echo "  same test on the PCA9555 @0x26 for comparison:"
pok=0; pbad=0; i=1
while [ $i -le 20 ]; do
    if S i2cget -f -y 0 0x26 0x00 >/dev/null 2>&1; then pok=$((pok+1)); else pbad=$((pbad+1)); fi
    i=$((i+1))
done
echo "  reads of pca9555: $pok ok, $pbad failed (of 20)"

echo "  CCI timeouts now: $(S dmesg | grep -c 'cci.*timeout')"

echo
echo "=============================================="
echo " PART 2 - power-on sequence sweep"
echo "=============================================="
echo "*** WATCH THE PANEL. Tell me which PHASE (if any) makes it light. ***"
echo

echo "--- PHASE A (in 3s): REG_POWERON=1 + PWM=255   [v1-firmware style] ---"
sleep 3
S i2cset -f -y 0 0x45 0x85 0x01 2>&1
sleep 1
S i2cset -f -y 0 0x45 0x86 0xff 2>&1
echo "    ...holding 10s"
sleep 10

echo "--- PHASE B (in 3s): PORTB=0x80, PORTA=0x04, PORTC=0x0f, PWM=255  [v2 port style] ---"
sleep 3
S i2cset -f -y 0 0x45 0x82 0x80 2>&1
sleep 1
S i2cset -f -y 0 0x45 0x81 0x04 2>&1
sleep 1
S i2cset -f -y 0 0x45 0x83 0x0f 2>&1
sleep 1
S i2cset -f -y 0 0x45 0x86 0xff 2>&1
echo "    ...holding 10s"
sleep 10

echo "--- PHASE C (in 3s): via the DRIVER (backlight sysfs 0 -> 255) ---"
sleep 3
S sh -c 'echo 0 > /sys/class/backlight/0-0045/brightness'
sleep 2
S sh -c 'echo 255 > /sys/class/backlight/0-0045/brightness'
echo "    ...holding 10s"
sleep 10

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
echo
echo "CCI timeouts at end: $(S dmesg | grep -c 'cci.*timeout')"

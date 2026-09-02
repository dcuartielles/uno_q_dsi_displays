#!/bin/sh
# Runs ON the UNO Q. Stdin secrets contract: 1. sudo password  2. SSID  3. wifi pw
# Moment of truth for the ICN6211 theory: is the bridge configured, and does
# the panel show anything?
unset HISTFILE
IFS= read -r SUDO_PASS; SUDO_PASS=$(printf '%s' "$SUDO_PASS" | tr -d '\r')
IFS= read -r WIFI_SSID
IFS= read -r WIFI_PASS
S() { printf '%s\n' "$SUDO_PASS" | sudo -S -p '' "$@"; }
S true 2>/dev/null || { echo "SUDO PASSWORD REJECTED"; exit 1; }

echo "=== chipone messages (errors would show here) ==="
dmesg | grep -iE 'chipone|icn6211' | grep -viE 'Modules linked|call trace|^\[.*\] [ x][0-9]' | head -15

echo
echo "=== did the DSI link come up cleanly? ==="
dmesg | grep -c dsi_err
dmesg | grep -iE 'dsi_err|failed to attach|deferred probe pending' | tail -6

echo
echo "=== the bridge's view of the mode ==="
S modetest -M msm -c 2>/dev/null | sed -n '1,14p'

echo
echo "=== DRM / framebuffer ==="
for s in /sys/class/drm/*/status; do [ -f "$s" ] && echo "  $(basename "$(dirname "$s")") => $(cat "$s")"; done
cat /sys/class/graphics/fb0/virtual_size 2>/dev/null
cat /sys/class/graphics/fb0/bits_per_pixel 2>/dev/null

echo
echo "=== backlight to maximum, all known protocols ==="
BL=$(ls -d /sys/class/backlight/*/ 2>/dev/null | head -1)
B=$(basename "$(ls -d /sys/bus/i2c/devices/*-0045 2>/dev/null | head -1)" | cut -d- -f1)
[ -n "$BL" ] && S sh -c "echo 255 > $BL/brightness"
S i2cset -f -y "$B" 0x45 0x86 0xff 2>/dev/null   # protocol A
S i2cset -f -y "$B" 0x45 0xab 0x00 2>/dev/null   # protocol C (inverted)
S i2cset -f -y "$B" 0x45 0xaa 0x01 2>/dev/null
S i2cset -f -y "$B" 0x45 0x96 0xff 2>/dev/null   # protocol B
echo "  backlight sysfs = $(cat "$BL/brightness" 2>/dev/null)"

echo
echo "*** WATCH THE PANEL: RED / GREEN / BLUE / WHITE, then colour bars ***"
sleep 3
python3 - <<'PY'
import time
W,H=800,480
def fill(b,g,r):
    with open('/dev/fb0','wb') as f: f.write(bytes([b,g,r,255])*(W*H))
for n,c in (("RED",(0,0,255)),("GREEN",(0,255,0)),("BLUE",(255,0,0)),("WHITE",(255,255,255))):
    print("  ->",n,flush=True); fill(*c); time.sleep(4)
bars=[(255,255,255),(0,255,255),(255,255,0),(0,255,0),(255,0,255),(0,0,255),(255,0,0),(0,0,0)]
row=b''
for x in range(W):
    b,g,r=bars[min(x*len(bars)//W,len(bars)-1)]
    row+=bytes([b,g,r,255])
with open('/dev/fb0','wb') as f: f.write(row*H)
print("  -> COLOUR BARS (left on screen)",flush=True)
PY

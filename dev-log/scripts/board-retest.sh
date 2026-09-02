#!/bin/sh
# Runs ON the UNO Q. Stdin secrets contract: 1. sudo password  2. SSID  3. wifi pw
#
# Fresh-boot retest: report the state the driver reached on its own, then
# blink the backlight, then paint full-screen colours and colour bars.
unset HISTFILE
IFS= read -r SUDO_PASS; SUDO_PASS=$(printf '%s' "$SUDO_PASS" | tr -d '\r')
IFS= read -r WIFI_SSID
IFS= read -r WIFI_PASS
S() { printf '%s\n' "$SUDO_PASS" | sudo -S -p '' "$@"; }
S true 2>/dev/null || { echo "SUDO PASSWORD REJECTED"; exit 1; }

BL=/sys/class/backlight/0-0045

echo "=== fresh boot state ==="
uptime
echo "kernel $(uname -r)"
for s in /sys/class/drm/*/status; do
    [ -f "$s" ] && echo "  $(basename "$(dirname "$s")") => $(cat "$s")"
done
echo "  backlight brightness=$(cat $BL/brightness 2>/dev/null) bl_power=$(cat $BL/bl_power 2>/dev/null)"
for r in /sys/class/regulator/*/; do
    n=$(cat "$r/name" 2>/dev/null)
    case "$n" in *tc358762*) echo "  regulator $n: $(cat "$r/state" 2>/dev/null) (users=$(cat "$r/num_users" 2>/dev/null))";; esac
done
echo "  CCI i2c timeouts this boot: $(S dmesg | grep -c 'cci.*timeout')"

echo
echo "=== i2c scan (does the Goodix touch @0x14 appear now?) ==="
S i2cdetect -y -r 0 2>&1 | head -8

echo
echo "=== display dmesg, this boot ==="
S dmesg | grep -iE 'tc358762|attiny|panel|dsi_err|backlight|drm' | tail -12

echo
echo "*** WATCH THE PANEL - backlight blink x3, then colours ***"
sleep 3
i=1
while [ $i -le 3 ]; do
    S sh -c "echo 0 > $BL/brightness"; sleep 2
    S sh -c "echo 255 > $BL/brightness"; sleep 2
    i=$((i+1))
done

python3 - <<'PY'
import time
W, H = 800, 480
def fill(b, g, r):
    with open('/dev/fb0','wb') as f:
        f.write(bytes([b,g,r,255])*(W*H))
for name, c in (("RED",(0,0,255)), ("GREEN",(0,255,0)), ("BLUE",(255,0,0)), ("WHITE",(255,255,255))):
    print("  ->", name, flush=True); fill(*c); time.sleep(3)
bars=[(255,255,255),(0,255,255),(255,255,0),(0,255,0),(255,0,255),(0,0,255),(255,0,0),(0,0,0)]
row=b''
for x in range(W):
    b,g,r=bars[min(x*len(bars)//W,len(bars)-1)]
    row+=bytes([b,g,r,255])
with open('/dev/fb0','wb') as f:
    f.write(row*H)
print("  -> COLOUR BARS (left on screen)", flush=True)
PY

S sh -c "echo 255 > $BL/brightness"
echo
echo "backlight left at $(cat $BL/brightness)"
echo "dsi errors: $(S dmesg | grep -c dsi_err)"

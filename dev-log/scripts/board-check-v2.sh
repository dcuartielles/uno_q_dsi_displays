#!/bin/sh
# Runs ON the UNO Q. Stdin secrets contract: 1. sudo password  2. SSID  3. wifi pw
# Did the RPi-faithful v2 overlay bring the 5-inch panel up?
unset HISTFILE
IFS= read -r SUDO_PASS; SUDO_PASS=$(printf '%s' "$SUDO_PASS" | tr -d '\r')
IFS= read -r WIFI_SSID
IFS= read -r WIFI_PASS
S() { printf '%s\n' "$SUDO_PASS" | sudo -S -p '' "$@"; }
S true 2>/dev/null || { echo "SUDO PASSWORD REJECTED"; exit 1; }

echo "=== config ==="
arduino-linux-config carrier show 2>&1 | head -6

echo
echo "=== THE KEY QUESTION: did bridge_reg / the attiny writes succeed? ==="
dmesg | grep -i 'attiny-dbg' | head -25

echo
echo "=== regulators ==="
for r in /sys/class/regulator/*/; do
    n=$(cat "$r/name" 2>/dev/null)
    case "$n" in *bridge*|*tc358762*|*panel*) echo "  $n: $(cat "$r/state" 2>/dev/null) users=$(cat "$r/num_users" 2>/dev/null)";; esac
done

echo
echo "=== DRM ==="
ls /sys/class/drm/
for s in /sys/class/drm/*/status; do
    [ -f "$s" ] && echo "  $(basename "$(dirname "$s")") => $(cat "$s")"
done
for m in /sys/class/drm/*/modes; do
    [ -f "$m" ] && echo "  modes: $(tr '\n' ' ' < "$m")"
done
cat /sys/class/graphics/fb0/virtual_size 2>/dev/null

echo
echo "=== backlight ==="
for b in /sys/class/backlight/*/; do
    echo "  $b cur=$(cat "$b/brightness" 2>/dev/null) power=$(cat "$b/bl_power" 2>/dev/null)"
done

echo
echo "=== bridge / panel / touch dmesg ==="
dmesg | grep -iE 'tc358762|panel-simple|panel-dpi|bridge|dsi_err|edt_ft5|ft5506|reg-fixed' | tail -20

echo
echo "=== errors ==="
dmesg | grep -iE '\-110|\-517|\-ENXIO|fail|error' | grep -iE 'panel|bridge|dsi|regulator|attiny|ft5' | tail -10

BL=$(ls -d /sys/class/backlight/*/ 2>/dev/null | head -1)
if [ -n "$BL" ]; then
    echo
    echo "*** WATCH THE PANEL: backlight blink x3, then colours ***"
    sleep 3
    i=1
    while [ $i -le 3 ]; do
        S sh -c "echo 0 > $BL/brightness";   sleep 2
        S sh -c "echo 255 > $BL/brightness"; sleep 2
        i=$((i+1))
    done
fi

if [ -e /dev/fb0 ]; then
python3 - <<'PY'
import time
W,H=800,480
def fill(b,g,r):
    with open('/dev/fb0','wb') as f: f.write(bytes([b,g,r,255])*(W*H))
for n,c in (("RED",(0,0,255)),("GREEN",(0,255,0)),("BLUE",(255,0,0)),("WHITE",(255,255,255))):
    print("  ->",n,flush=True); fill(*c); time.sleep(3)
bars=[(255,255,255),(0,255,255),(255,255,0),(0,255,0),(255,0,255),(0,0,255),(255,0,0),(0,0,0)]
row=b''
for x in range(W):
    b,g,r=bars[min(x*len(bars)//W,len(bars)-1)]
    row+=bytes([b,g,r,255])
with open('/dev/fb0','wb') as f: f.write(row*H)
print("  -> COLOUR BARS",flush=True)
PY
else
    echo ">>> no /dev/fb0"
fi

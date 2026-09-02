#!/bin/sh
# Runs ON the UNO Q. Stdin secrets contract: 1. sudo password  2. SSID  3. wifi pw
# Did programming the bridge's DPI timing registers make the panel work?
unset HISTFILE
IFS= read -r SUDO_PASS; SUDO_PASS=$(printf '%s' "$SUDO_PASS" | tr -d '\r')
IFS= read -r WIFI_SSID
IFS= read -r WIFI_PASS
S() { printf '%s\n' "$SUDO_PASS" | sudo -S -p '' "$@"; }
S true 2>/dev/null || { echo "SUDO PASSWORD REJECTED"; exit 1; }

echo "=== tc358762 init: did it run, with what mode? ==="
dmesg | grep -i 'tc358762-dbg' | head -5

echo
echo "=== attiny trace ==="
dmesg | grep -i 'attiny-dbg' | head -20

echo
echo "=== regulator (is_enabled now uses the cache) ==="
for r in /sys/class/regulator/*/; do
    n=$(cat "$r/name" 2>/dev/null)
    case "$n" in *bridge*|*tc358762*) echo "  $n: $(cat "$r/state" 2>/dev/null) users=$(cat "$r/num_users" 2>/dev/null)";; esac
done

echo
echo "=== DRM ==="
for s in /sys/class/drm/*/status; do
    [ -f "$s" ] && echo "  $(basename "$(dirname "$s")") => $(cat "$s")"
done
for m in /sys/class/drm/*/modes; do
    [ -f "$m" ] && echo "  modes: $(tr '\n' ' ' < "$m")"
done

echo
echo "=== DSI errors (was status=4 every boot) ==="
dmesg | grep -c dsi_err
dmesg | grep dsi_err | tail -3

echo
echo "=== backlight ==="
BL=$(ls -d /sys/class/backlight/*/ 2>/dev/null | head -1)
echo "  $BL cur=$(cat "$BL/brightness" 2>/dev/null)"

echo
echo "*** WATCH THE PANEL: blink x3, then RED/GREEN/BLUE/WHITE, then bars ***"
sleep 3
if [ -n "$BL" ]; then
    i=1
    while [ $i -le 3 ]; do
        S sh -c "echo 0 > $BL/brightness";   sleep 2
        S sh -c "echo 255 > $BL/brightness"; sleep 2
        i=$((i+1))
    done
fi

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

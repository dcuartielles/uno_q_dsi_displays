#!/bin/sh
# Runs ON the UNO Q. Stdin secrets contract: 1. sudo password  2. SSID  3. wifi pw
# Did the retries make the critical PORTC writes land?
unset HISTFILE
IFS= read -r SUDO_PASS; SUDO_PASS=$(printf '%s' "$SUDO_PASS" | tr -d '\r')
IFS= read -r WIFI_SSID
IFS= read -r WIFI_PASS
S() { printf '%s\n' "$SUDO_PASS" | sudo -S -p '' "$@"; }

echo "=== attiny-dbg trace ==="
dmesg | grep -i 'attiny-dbg' | head -40

echo
echo "=== the two writes that used to fail ==="
dmesg | grep -iE 'attiny-dbg: WRITE port reg=0x83' | head -10

echo
echo "=== panel / bridge chain ==="
dmesg | grep -iE 'tc358762|panel-simple|dsi_err|drm.*panel|backlight' | tail -12

echo
echo "=== DRM ==="
ls /sys/class/drm/
for s in /sys/class/drm/*/status; do
    [ -f "$s" ] && echo "  $(basename "$(dirname "$s")") => $(cat "$s")"
done
for m in /sys/class/drm/*/modes; do
    [ -f "$m" ] && echo "  modes: $(tr '\n' ' ' < "$m")"
done

echo
echo "=== regulator + backlight ==="
for r in /sys/class/regulator/*/; do
    n=$(cat "$r/name" 2>/dev/null)
    case "$n" in *tc358762*) echo "  $n: $(cat "$r/state" 2>/dev/null)";; esac
done
BL=$(ls -d /sys/class/backlight/*/ 2>/dev/null | head -1)
echo "  backlight: ${BL:-none} brightness=$(cat "$BL/brightness" 2>/dev/null)"

echo
echo "*** WATCH THE PANEL: blink x3 then RED/GREEN/BLUE/WHITE then bars ***"
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

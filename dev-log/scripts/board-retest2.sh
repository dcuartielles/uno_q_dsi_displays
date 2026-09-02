#!/bin/sh
# Runs ON the UNO Q. Stdin secrets contract: 1. sudo password  2. SSID  3. wifi pw
#
# Same retest, but WITHOUT hardcoded i2c bus numbers - they are not stable
# across boots on this board (the ANX7625 moved from 3-0058 to 2-0058).
unset HISTFILE
IFS= read -r SUDO_PASS; SUDO_PASS=$(printf '%s' "$SUDO_PASS" | tr -d '\r')
IFS= read -r WIFI_SSID
IFS= read -r WIFI_PASS
S() { printf '%s\n' "$SUDO_PASS" | sudo -S -p '' "$@"; }
S true 2>/dev/null || { echo "SUDO PASSWORD REJECTED"; exit 1; }

echo "=== i2c bus map this boot ==="
for d in /sys/bus/i2c/devices/i2c-*; do
    echo "  $(basename "$d") : $(cat "$d/name" 2>/dev/null)"
done
echo "--- bound i2c clients ---"
ls /sys/bus/i2c/devices/ | grep -E '^[0-9]+-[0-9a-f]+$'

# locate the attiny (…-0045) and its bus
ATT=$(ls -d /sys/bus/i2c/devices/*-0045 2>/dev/null | head -1)
BUS=$(basename "$ATT" 2>/dev/null | cut -d- -f1)
echo "  attiny device: ${ATT:-NOT PRESENT}   bus: ${BUS:-?}"

BL=$(ls -d /sys/class/backlight/*/ 2>/dev/null | head -1)
echo "  backlight dev: ${BL:-NONE}"
[ -n "$BL" ] && echo "  brightness=$(cat "$BL/brightness" 2>/dev/null) bl_power=$(cat "$BL/bl_power" 2>/dev/null)"

echo
echo "=== scan every i2c bus ==="
for d in /sys/bus/i2c/devices/i2c-*; do
    n=$(basename "$d" | cut -d- -f2)
    printf -- "--- bus %s (%s) ---\n" "$n" "$(cat "$d/name" 2>/dev/null)"
    S i2cdetect -y -r "$n" 2>&1 | sed -n '2,9p'
done

echo
echo "=== gpiochips (attiny should appear) ==="
S gpiodetect 2>&1

if [ -z "$BL" ]; then
    echo
    echo ">>> NO BACKLIGHT DEVICE - the attiny driver did not register one this boot."
    echo ">>> Skipping blink."
else
    echo
    echo "*** WATCH THE PANEL - backlight blink x4 (2s on / 2s off) ***"
    sleep 3
    i=1
    while [ $i -le 4 ]; do
        S sh -c "echo 0 > $BL/brightness";   sleep 2
        S sh -c "echo 255 > $BL/brightness"; sleep 2
        i=$((i+1))
    done
fi

echo
echo "=== paint colours ==="
python3 - <<'PY'
import time
W,H=800,480
def fill(b,g,r):
    with open('/dev/fb0','wb') as f: f.write(bytes([b,g,r,255])*(W*H))
for name,c in (("RED",(0,0,255)),("GREEN",(0,255,0)),("BLUE",(255,0,0)),("WHITE",(255,255,255))):
    print("  ->",name,flush=True); fill(*c); time.sleep(3)
bars=[(255,255,255),(0,255,255),(255,255,0),(0,255,0),(255,0,255),(0,0,255),(255,0,0),(0,0,0)]
row=b''
for x in range(W):
    b,g,r=bars[min(x*len(bars)//W,len(bars)-1)]
    row+=bytes([b,g,r,255])
with open('/dev/fb0','wb') as f: f.write(row*H)
print("  -> COLOUR BARS (left on screen)",flush=True)
PY

[ -n "$BL" ] && S sh -c "echo 255 > $BL/brightness"
echo
echo "regulators:"
for r in /sys/class/regulator/*/; do
    n=$(cat "$r/name" 2>/dev/null)
    case "$n" in *tc358762*) echo "  $n: $(cat "$r/state" 2>/dev/null) users=$(cat "$r/num_users" 2>/dev/null)";; esac
done

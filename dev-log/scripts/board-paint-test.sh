#!/bin/sh
# Runs ON the UNO Q. Stdin secrets contract: 1. sudo password  2. SSID  3. wifi pw
#
# Unmistakable visual test: full-screen RED, GREEN, BLUE for 3s each, then
# leaves colour bars on screen.
unset HISTFILE
IFS= read -r SUDO_PASS; SUDO_PASS=$(printf '%s' "$SUDO_PASS" | tr -d '\r')
IFS= read -r WIFI_SSID
IFS= read -r WIFI_PASS
S() { printf '%s\n' "$SUDO_PASS" | sudo -S -p '' "$@"; }

BL=/sys/class/backlight/0-0045
S sh -c "echo 255 > $BL/brightness"

echo "framebuffer: $(cat /sys/class/graphics/fb0/virtual_size) @ $(cat /sys/class/graphics/fb0/bits_per_pixel)bpp"
echo
echo "*** WATCH THE PANEL - 3 full-screen colours, 3 seconds each ***"
echo

python3 - <<'PY'
import time
W, H = 800, 480
def fill(b, g, r):
    with open('/dev/fb0', 'wb') as f:
        f.write(bytes([b, g, r, 255]) * (W * H))

for name, bgr in (("RED", (0, 0, 255)), ("GREEN", (0, 255, 0)), ("BLUE", (255, 0, 0))):
    print("  ->", name, flush=True)
    fill(*bgr)
    time.sleep(3)

# eight vertical colour bars, leave them up
bars = [(255,255,255),(0,255,255),(255,255,0),(0,255,0),
        (255,0,255),(0,0,255),(255,0,0),(0,0,0)]
row = b''
for x in range(W):
    b, g, r = bars[min(x * len(bars) // W, len(bars) - 1)]
    row += bytes([b, g, r, 255])
with open('/dev/fb0', 'wb') as f:
    f.write(row * H)
print("  -> COLOUR BARS (left on screen)", flush=True)
PY

echo
echo "=== dsi errors during the test ==="
S dmesg | grep -iE 'dsi_err|tc358762|underrun' | tail -5
echo
echo "backlight = $(cat $BL/brightness)"

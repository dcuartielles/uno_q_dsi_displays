#!/bin/sh
# Paint the framebuffer so you can confirm the panel is really driven.
#   sudo ./scripts/test-display.sh
HERE=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
. "$HERE/lib/common.sh"
need_root "$@"

[ -e /dev/fb0 ] || die "no /dev/fb0 - the display pipeline is not up. Run scripts/40-verify.sh"

BL=$(ls -d /sys/class/backlight/*/ 2>/dev/null | head -1)
if [ -n "$BL" ]; then
    echo 255 > "$BL/brightness" 2>/dev/null || true
    ok "backlight set to $(cat "$BL/brightness" 2>/dev/null)"
fi

W=$(cut -d, -f1 /sys/class/graphics/fb0/virtual_size)
H=$(cut -d, -f2 /sys/class/graphics/fb0/virtual_size)
BPP=$(cat /sys/class/graphics/fb0/bits_per_pixel)
say "  framebuffer ${W}x${H} @ ${BPP}bpp"
[ "$BPP" = "32" ] || warn "expected 32bpp; the patterns below assume BGRA"

step "Watch the panel: red, green, blue, white, then colour bars"
python3 - "$W" "$H" <<'PY'
import sys, time
W, H = int(sys.argv[1]), int(sys.argv[2])

def fill(b, g, r):
    with open('/dev/fb0', 'wb') as f:
        f.write(bytes([b, g, r, 255]) * (W * H))

for name, c in (("RED", (0, 0, 255)), ("GREEN", (0, 255, 0)),
                ("BLUE", (255, 0, 0)), ("WHITE", (255, 255, 255))):
    print("  ->", name, flush=True)
    fill(*c)
    time.sleep(2)

bars = [(255,255,255), (0,255,255), (255,255,0), (0,255,0),
        (255,0,255), (0,0,255), (255,0,0), (0,0,0)]
row = b''
for x in range(W):
    b, g, r = bars[min(x * len(bars) // W, len(bars) - 1)]
    row += bytes([b, g, r, 255])
with open('/dev/fb0', 'wb') as f:
    f.write(row * H)
print("  -> COLOUR BARS", flush=True)
PY

say ""
say "If you saw those, the display works."
say "If the image is garbled, torn or rolling, the timings in your .panel file"
say "are wrong - see docs/TROUBLESHOOTING.md."

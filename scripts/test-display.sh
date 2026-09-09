#!/bin/sh
# Paint the framebuffer so you can confirm the panel is really driven.
#   sudo ./scripts/test-display.sh
HERE=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
. "$HERE/lib/common.sh"
need_root "$@"

[ -e /dev/fb0 ] || die "no /dev/fb0 - the display pipeline is not up. Run scripts/40-verify.sh"

# Xorg owns the display, and while it does, writing to /dev/fb0 paints nothing
# at all - the command succeeds, the screen does not change, and the obvious
# conclusion is that the panel is broken. Switch to a spare text VT first,
# which hands the framebuffer back to fbcon, and switch back afterwards.
# --hold leaves the last pattern on screen and the VT switched, for a caller
# that wants to ask a human about it. 45-confirm-display.sh does exactly that,
# and restores the VT itself afterwards.
HOLD=0
for _a in "$@"; do [ "$_a" = "--hold" ] && HOLD=1; done

# Which VT to paint on. NOT one of the first six: systemd's autovt spawns a
# getty the moment you switch to those, and its login prompt paints straight
# over the image - the number appears, then a terminal replaces it. tty7 is
# usually X, so the first genuinely free one is tty8.
#
# logind's NAutoVTs decides how many are auto-spawned; read it rather than
# assume, and stay clear of wherever X actually is.
PAINT_VT=${PAINT_VT:-}
if [ -z "$PAINT_VT" ]; then
    # Consoles 1..6 get a getty from systemd's autovt the moment you switch to
    # them, and 7 is where X usually sits. Rather than deduce that, check: take
    # the first console above them with no getty running on it.
    for _v in 8 9 10 11 12; do
        [ -c "/dev/tty$_v" ] || continue
        systemctl is-active "getty@tty$_v.service" >/dev/null 2>&1 && continue
        PAINT_VT=$_v
        break
    done
    [ -n "$PAINT_VT" ] || PAINT_VT=8
fi

BACK_VT=$(fgconsole 2>/dev/null || true)
case "$BACK_VT" in ''|*[!0-9]*) BACK_VT=7 ;; esac

if have_cmd chvt; then
    chvt "$PAINT_VT" 2>/dev/null || die "could not switch to tty$PAINT_VT"
    sleep 1

    BACK_VT=$(fgconsole 2>/dev/null || echo 7)
    chvt "$PAINT_VT" 2>/dev/null || true
    sleep 1
    restore_vt() { chvt "$BACK_VT" 2>/dev/null || true; }
    trap restore_vt EXIT INT TERM
else
    warn "chvt not available - if the desktop is running you may see nothing"
fi

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

# A framebuffer line is STRIDE bytes, which is not always width * bpp/8. On a
# 720-wide panel the kernel pads each line to 2944 bytes where the naive
# calculation gives 2880, and writing the short rows shears every line 16
# pixels further left than the last - dense diagonal striping that looks
# exactly like a panel driven with the wrong timings.
#
# That is not hypothetical: it made a working 5 inch panel look broken, and the
# confirmation step would have reported it as the wrong panel. The 800-wide
# panels are already 64-byte aligned, which is why this hid for so long.
STRIDE=$(cat /sys/class/graphics/fb0/stride 2>/dev/null || echo "")
[ -n "$STRIDE" ] || STRIDE=$(( W * BPP / 8 ))
[ "$STRIDE" = "$(( W * BPP / 8 ))" ] || \
    say "  line stride is $STRIDE bytes, not $(( W * BPP / 8 )) - padding honoured"

step "Watch the panel: red, green, blue, white, then colour bars"
python3 - "$W" "$H" "$STRIDE" <<'PY'
import sys, time
W, H, STRIDE = int(sys.argv[1]), int(sys.argv[2]), int(sys.argv[3])
PAD = b'\x00' * max(0, STRIDE - W * 4)

def paint(row):
    """One row of W pixels, padded out to the real line stride."""
    with open('/dev/fb0', 'wb') as f:
        f.write((row + PAD) * H)

def fill(b, g, r):
    paint(bytes([b, g, r, 255]) * W)

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
paint(row)
print("  -> COLOUR BARS", flush=True)
PY

say ""
say "If you saw those, the display works."
say "If the image is garbled, torn or rolling, the timings in your .panel file"
say "are wrong - see docs/TROUBLESHOOTING.md."

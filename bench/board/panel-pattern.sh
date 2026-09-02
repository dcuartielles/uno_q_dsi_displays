#!/bin/sh
# Show a known full-screen pattern on the DSI panel. Runs ON the board.
#
#   panel-pattern.sh <black|white|red|green|blue|grey|bars> [brightness 0-255]
#   panel-pattern.sh restore
#
# Why the VT switch
# -----------------
# Xorg owns the display, so writing to /dev/fb0 while the desktop is up does
# nothing at all. Switching to a spare text VT hands the framebuffer back to
# fbcon, and then a plain write to /dev/fb0 paints the whole panel. 'restore'
# switches back to whatever VT the desktop was on.
#
# This is what lets the benchmark verify the panel is showing the RIGHT thing
# rather than merely glowing: paint red, green and blue in turn and check the
# camera agrees. It also gives a proper black reference, which matters because
# this panel cannot be blanked from software at all - both brightness=0 and
# bl_power=1 only dim it.
set -eu

BENCH_VT=${BENCH_VT:-3}
VT_STATE=/run/uno-q-bench.vt

pattern=${1:?usage: $0 <black|white|red|green|blue|grey|bars|restore> [brightness]}
brightness=${2:-}

set_brightness() {
    [ -n "$1" ] || return 0
    for b in /sys/class/backlight/*/brightness; do
        [ -e "$b" ] || continue
        printf '%s' "$1" > "$b" 2>/dev/null || true
    done
}

if [ "$pattern" = "restore" ]; then
    back=7
    [ -r "$VT_STATE" ] && back=$(cat "$VT_STATE")
    chvt "$back" 2>/dev/null || true
    rm -f "$VT_STATE"
    set_brightness "${brightness:-255}"
    echo "restored to vt $back"
    exit 0
fi

# Remember where we came from, once, so restore lands back on the desktop.
if [ ! -r "$VT_STATE" ]; then
    cur=$(fgconsole 2>/dev/null || echo 7)
    [ "$cur" = "$BENCH_VT" ] || printf '%s' "$cur" > "$VT_STATE"
fi

chvt "$BENCH_VT" 2>/dev/null || true
# fbcon needs a moment to take the console over after the switch.
sleep 0.4

python3 - "$pattern" <<'PY'
import sys, struct

pattern = sys.argv[1]

def sysfs(path, default=None):
    try:
        return open(path).read().strip()
    except OSError:
        if default is None:
            raise
        return default

w, h = (int(x) for x in sysfs("/sys/class/graphics/fb0/virtual_size").split(","))
bpp = int(sysfs("/sys/class/graphics/fb0/bits_per_pixel", "32"))
stride = int(sysfs("/sys/class/graphics/fb0/stride", str(w * bpp // 8)))

SOLID = {
    "black": (0, 0, 0),
    "white": (255, 255, 255),
    "red":   (255, 0, 0),
    "green": (0, 255, 0),
    "blue":  (0, 0, 255),
    "grey":  (128, 128, 128),
}

def pack(r, g, b):
    if bpp == 32:
        return struct.pack("<I", (r << 16) | (g << 8) | b)
    if bpp == 16:                       # RGB565
        return struct.pack("<H", ((r >> 3) << 11) | ((g >> 2) << 5) | (b >> 3))
    if bpp == 24:
        return bytes((b, g, r))
    raise SystemExit("unsupported bits_per_pixel: %d" % bpp)

row_pad = b"\x00" * max(0, stride - w * bpp // 8)

with open("/dev/fb0", "wb") as fb:
    if pattern == "bars":
        # Vertical colour bars - lots of edges, so it also exercises the
        # "is there an image" check rather than just overall brightness.
        bars = [(255, 255, 255), (255, 255, 0), (0, 255, 255), (0, 255, 0),
                (255, 0, 255), (255, 0, 0), (0, 0, 255), (0, 0, 0)]
        row = b"".join(pack(*bars[(x * len(bars)) // w]) for x in range(w)) + row_pad
        fb.write(row * h)
    else:
        if pattern not in SOLID:
            raise SystemExit("unknown pattern: %s" % pattern)
        row = pack(*SOLID[pattern]) * w + row_pad
        fb.write(row * h)
PY

set_brightness "$brightness"
echo "showing $pattern on vt $BENCH_VT"

#!/bin/sh
# Paint a large number on the panel.
#
#   sudo ./scripts/show-number.sh 3                  # paint, restore the desktop
#   sudo ./scripts/show-number.sh 3 --hold           # leave it up
#   sudo ./scripts/show-number.sh 3 --until-touch    # leave it up until touched
#
# Why a number and not just a pattern
# -----------------------------------
# When testing a run of identical panels, a colour bar test looks the same on
# every one of them - including on the panel you already tested, if the new one
# never came up and you are looking at a screen that simply never changed. A
# number that increments is proof the picture in front of you was drawn for
# THIS panel and not left over from the last, which is what makes it worth
# photographing.
#
# --until-touch holds it there for as long as it takes to get the photograph,
# and dismisses it when a finger lands. That is not just convenience: it makes
# the dismissal a touch test. If the number goes away when you touch it, the
# touchscreen works - on the panel in front of you, right now, which is a
# stronger statement than any check this repository can make from software.
#
# It is drawn straight into the framebuffer with no fonts and no libraries: a
# 5x7 bitmap per digit, scaled up to fill the screen. Nothing to install on the
# board, and it works on a text VT where the desktop is not running.
set -e
HERE=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
. "$HERE/lib/common.sh"
need_root "$@"

NUMBER=${1:?usage: $0 <number> [--hold|--until-touch] [--timeout SECONDS]}
HOLD=0
WAIT_TOUCH=0
TIMEOUT=300
prev=
for a in "$@"; do
    case "$prev" in --timeout) TIMEOUT=$a ;; esac
    case "$a" in
        --hold)         HOLD=1 ;;
        --until-touch)  WAIT_TOUCH=1; HOLD=1 ;;
    esac
    prev=$a
done

[ -e /dev/fb0 ] || die "no /dev/fb0 - the display pipeline is not up"

W=$(cut -d, -f1 /sys/class/graphics/fb0/virtual_size)
H=$(cut -d, -f2 /sys/class/graphics/fb0/virtual_size)
BPP=$(cat /sys/class/graphics/fb0/bits_per_pixel)

# A framebuffer line is stride bytes, which is not always width * bpp/8 - on a
# 720-wide panel the kernel pads 2880 up to 2944, and writing the short rows
# shears the image into something that looks exactly like broken timings.
STRIDE=$(cat /sys/class/graphics/fb0/stride 2>/dev/null || echo "")
[ -n "$STRIDE" ] || STRIDE=$(( W * BPP / 8 ))

BL=$(ls -d /sys/class/backlight/*/ 2>/dev/null | head -1)
[ -n "$BL" ] && { echo 255 > "$BL/brightness" 2>/dev/null || true; }

# Xorg owns the display while the desktop is up, and a write to /dev/fb0 then
# paints nothing at all - succeeding silently, which reads as a dead panel.
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

# fgconsole prints nothing when there is no controlling terminal, which is the
# case over adb - so its output is checked, not just its exit status.
BACK_VT=$(fgconsole 2>/dev/null || true)
case "$BACK_VT" in ''|*[!0-9]*) BACK_VT=7 ;; esac

have_cmd chvt || die "chvt is not available"

# Take the console and CONFIRM it. chvt returning 0 only means the request was
# accepted; whether it stuck is a separate question, and painting into a
# console someone else owns is discarded in silence.
take_vt() {
    chvt "$PAINT_VT" 2>/dev/null || return 1
    _t=0
    while [ "$_t" -lt 20 ]; do
        [ "$(cat /sys/class/tty/tty0/active 2>/dev/null)" = "tty$PAINT_VT" ] \
            && return 0
        _t=$((_t + 1))
        sleep 0.25
    done
    return 1
}
take_vt || die "could not take tty$PAINT_VT - something else holds the console"

if true; then
    sleep 1
    # No cursor in the photograph, and no console blanking part way through a
    # long wait for someone to fetch a camera.
    if have_cmd setterm; then
        setterm --cursor off > "/dev/tty$PAINT_VT" 2>/dev/null || true
        setterm --blank 0 --powersave off > "/dev/tty$PAINT_VT" 2>/dev/null || true
    fi
    [ "$HOLD" = 1 ] || trap 'chvt "$BACK_VT" 2>/dev/null || true' EXIT INT TERM
fi

# Rendered to a file first, so the wait loop can repaint instantly whenever the
# console is stolen and taken back.
FRAME=/run/uno-q-number.raw
python3 - "$W" "$H" "$STRIDE" "$NUMBER" "$FRAME" <<'PY'
import sys

W, H, STRIDE = int(sys.argv[1]), int(sys.argv[2]), int(sys.argv[3])
text, out = sys.argv[4], sys.argv[5]

# 5x7 bitmap digits. Enough for the job and small enough to read at a glance.
FONT = {
    "0": ("01110", "10001", "10011", "10101", "11001", "10001", "01110"),
    "1": ("00100", "01100", "00100", "00100", "00100", "00100", "01110"),
    "2": ("01110", "10001", "00001", "00010", "00100", "01000", "11111"),
    "3": ("11111", "00010", "00100", "00010", "00001", "10001", "01110"),
    "4": ("00010", "00110", "01010", "10010", "11111", "00010", "00010"),
    "5": ("11111", "10000", "11110", "00001", "00001", "10001", "01110"),
    "6": ("00110", "01000", "10000", "11110", "10001", "10001", "01110"),
    "7": ("11111", "00001", "00010", "00100", "01000", "01000", "01000"),
    "8": ("01110", "10001", "10001", "01110", "10001", "10001", "01110"),
    "9": ("01110", "10001", "10001", "01111", "00001", "00010", "01100"),
    "-": ("00000", "00000", "00000", "11111", "00000", "00000", "00000"),
}
glyphs = [FONT.get(c, FONT["-"]) for c in text]

GAP = 1                                   # blank columns between digits, in cells
cells_w = len(glyphs) * 5 + GAP * (len(glyphs) - 1)
cells_h = 7

# Fill about 70% of the smaller dimension, so it reads from across a bench
# whichever way the panel is mounted.
scale = max(1, min(W * 7 // (10 * cells_w), H * 7 // (10 * cells_h)))
px_w, px_h = cells_w * scale, cells_h * scale
x0, y0 = (W - px_w) // 2, (H - px_h) // 2

# Deliberately white on black: maximum contrast for a photograph, and a dark
# surround makes a panel that is lit but showing nothing obvious rather than
# merely dim.
BG = bytes((0, 0, 0, 255))
FG = bytes((255, 255, 255, 255))
PAD = b"\x00" * max(0, STRIDE - W * 4)

def row_for(y):
    if y < y0 or y >= y0 + px_h:
        return BG * W + PAD
    cell_y = (y - y0) // scale
    line = bytearray(BG * W)
    for gi, g in enumerate(glyphs):
        bits = g[cell_y]
        base = gi * (5 + GAP) * scale
        for cx, bit in enumerate(bits):
            if bit != "1":
                continue
            sx = x0 + base + cx * scale
            for px in range(sx, min(sx + scale, W)):
                if px >= 0:
                    line[px * 4:px * 4 + 4] = FG
    return bytes(line) + PAD

with open(out, "wb") as fh:
    fh.write(b"".join(row_for(y) for y in range(H)))
PY

cat "$FRAME" > /dev/fb0
ok "showing \"$NUMBER\" on the panel (tty$PAINT_VT)"

# ------------------------------------------------------------ wait for it ---
if [ "$WAIT_TOUCH" = 1 ]; then
    say "  Photograph it, then touch the screen to continue."
    say "  (touching it also proves the touchscreen works on this panel)"

    set +e
    python3 - "$TIMEOUT" "$PAINT_VT" "$FRAME" <<'PY'
import glob, os, re, select, sys, time

deadline = time.time() + float(sys.argv[1])
paint_vt, frame = "tty" + sys.argv[2], sys.argv[3]

# Find the touchscreen by capability rather than by name: this repository
# already drives two different controllers, and more will turn up. A device
# reporting multitouch position is a touchscreen whatever it calls itself.
devs = []
try:
    blocks = open("/proc/bus/input/devices").read().split("\n\n")
except IOError:
    blocks = []
for b in blocks:
    if "ABS=" not in b:
        continue
    abs_line = re.search(r"B: ABS=([0-9a-f]+)", b)
    if not abs_line:
        continue
    bits = int(abs_line.group(1), 16)
    # bit 0x35 is ABS_MT_POSITION_X - set by every multitouch panel here.
    if not (bits >> 0x35) & 1:
        continue
    for h in re.findall(r"event\d+", b):
        devs.append("/dev/input/" + h)

if not devs:
    devs = sorted(glob.glob("/dev/input/event*"))

fds = {}
for d in devs:
    try:
        fds[os.open(d, os.O_RDONLY | os.O_NONBLOCK)] = d
    except OSError:
        pass
if not fds:
    sys.exit(2)

def active_vt():
    try:
        return open("/sys/class/tty/tty0/active").read().strip()
    except IOError:
        return paint_vt

def repaint():
    try:
        with open(frame, "rb") as src, open("/dev/fb0", "wb") as fb:
            fb.write(src.read())
    except IOError:
        pass

# Hold the console. lightdm takes it back for its own reasons, and when it does
# the number vanishes mid-photograph with nothing logged anywhere.
steals = 0
while time.time() < deadline:
    r, _, _ = select.select(list(fds), [], [], 1.0)
    for fd in r:
        if os.read(fd, 4096):
            sys.exit(0)
    if active_vt() != paint_vt:
        steals += 1
        os.system("chvt %s" % paint_vt[3:])
        time.sleep(0.4)
        repaint()
        sys.stderr.write("  console was taken back (%d) - repainted\n" % steals)
sys.exit(1)
PY
    rc=$?
    set -e

    case "$rc" in
        0) ok "touched - the touchscreen works on this panel" ;;
        2) warn "no touchscreen input device found - cannot wait for a touch" ;;
        *) warn "no touch within ${TIMEOUT}s - the touchscreen may not be working" ;;
    esac
    chvt "$BACK_VT" 2>/dev/null || true
    rm -f "$FRAME"
    exit "$rc"
fi

[ "$HOLD" = 1 ] && say "  (left on screen; run with no --hold to restore the desktop)"
exit 0

#!/bin/sh
# Spin a spiral in the middle of the panel.
#
#   sudo ./scripts/show-spiral.sh                    # spin for 120s, then restore
#   sudo ./scripts/show-spiral.sh --seconds 30
#   sudo ./scripts/show-spiral.sh --until-touch      # spin until the glass is touched
#   sudo ./scripts/show-spiral.sh --hold             # spin until interrupted
#
# Why a moving picture and not another still
# ------------------------------------------
# show-number.sh proves a panel was painted for THIS panel. It cannot prove the
# panel is still being refreshed - a framebuffer that was written once and then
# froze looks exactly like a framebuffer that is being driven perfectly, and
# both photograph the same. Motion separates them: if the spiral turns, the
# pipeline is running end to end right now, DSI link included.
#
# A spiral in particular because it is drawn round the centre. On a ROUND panel
# - the Waveshare 4.0inch C is a 720x720 framebuffer on a circle of glass - the
# corners of that square are simply not there, so anything squared off gets its
# extremities cut away and nothing about the picture tells you whether the cut
# was the glass or the timings. A spiral inside the inscribed circle is
# entirely visible on a round panel AND on a square one, and it is
# rotationally symmetric, so a skewed or sheared picture shows up immediately
# as an oval.
#
# Like show-number.sh this is drawn straight into the framebuffer with no fonts
# and no libraries, honouring the stride, on a text VT where the desktop is not
# running.
set -e
HERE=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
. "$HERE/lib/common.sh"
need_root "$@"

SECONDS_TO_RUN=120
HOLD=0
WAIT_TOUCH=0
FPS=12
TURNS=4
prev=
for a in "$@"; do
    case "$prev" in
        --seconds) SECONDS_TO_RUN=$a ;;
        --fps)     FPS=$a ;;
        --turns)   TURNS=$a ;;
    esac
    case "$a" in
        --hold)        HOLD=1 ;;
        --until-touch) WAIT_TOUCH=1 ;;
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

# Which VT to paint on - the same reasoning as show-number.sh. Consoles 1..6
# get a getty from systemd's autovt the moment you switch to them, and 7 is
# where X usually sits, so take the first console above those with no getty.
PAINT_VT=${PAINT_VT:-}
if [ -z "$PAINT_VT" ]; then
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
# accepted; painting into a console someone else owns is discarded in silence.
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

sleep 1
if have_cmd setterm; then
    setterm --cursor off > "/dev/tty$PAINT_VT" 2>/dev/null || true
    setterm --blank 0 --powersave off > "/dev/tty$PAINT_VT" 2>/dev/null || true
fi

# Unlike show-number.sh --hold, this ALWAYS puts the desktop back. A still
# image left on the glass is a photograph waiting to be taken; a spinning one
# left behind is just a console nobody can get back.
trap 'chvt "$BACK_VT" 2>/dev/null || true' EXIT INT TERM

step "Spinning a spiral on the ${W}x${H} panel"
set +e
python3 "$HERE/tools/spiral.py" \
    --width "$W" --height "$H" --stride "$STRIDE" --bpp "$BPP" \
    --seconds "$SECONDS_TO_RUN" --fps "$FPS" --turns "$TURNS" \
    --vt "tty$PAINT_VT" \
    $( [ "$HOLD" = 1 ] && echo --hold ) \
    $( [ "$WAIT_TOUCH" = 1 ] && echo --until-touch )
rc=$?
set -e

case "$rc" in
    0) ok "done" ;;
    3) ok "touched - the touchscreen works on this panel" ;;
    *) warn "spiral exited with status $rc" ;;
esac

chvt "$BACK_VT" 2>/dev/null || true

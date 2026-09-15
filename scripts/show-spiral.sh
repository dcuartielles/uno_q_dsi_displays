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
. "$HERE/lib/paint.sh"
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

paint_fb_geometry
paint_take_vt

# Unlike show-number.sh --hold, this ALWAYS puts the desktop back. A still
# image left on the glass is a photograph waiting to be taken; a spinning one
# left behind is just a console nobody can get back.
trap 'paint_restore_vt' EXIT INT TERM

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

paint_restore_vt

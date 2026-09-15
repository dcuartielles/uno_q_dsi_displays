#!/bin/sh
# Drive into a tunnel of concentric rectangles.
#
#   sudo ./scripts/show-tunnel.sh                  # 120s, then restore
#   sudo ./scripts/show-tunnel.sh --seconds 30
#   sudo ./scripts/show-tunnel.sh --until-touch    # until the glass is touched
#   sudo ./scripts/show-tunnel.sh --hold           # until interrupted
#   sudo ./scripts/show-tunnel.sh --sway 0.15 --ratio 0.78
#
# The rectangular counterpart to show-spiral.sh. The spiral was written for a
# round panel and stays inside the inscribed circle, which leaves most of a
# wide panel unused; this fills the screen to all four edges, so it exercises
# the corners - and on a landscape panel that is exactly where a wrong mode or
# a wrong stride shows itself first.
#
# It keeps both properties that make a moving pattern worth having over a still
# one: a framebuffer written once and then frozen photographs identically to
# one being driven properly, so motion is the only thing that proves the panel
# is still being refreshed; and the geometry is known, so a wrong stride turns
# straight edges into staircases.
set -e
HERE=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
. "$HERE/lib/common.sh"
. "$HERE/lib/paint.sh"
need_root "$@"

SECONDS_TO_RUN=120
HOLD=0
WAIT_TOUCH=0
FPS=15
RATIO=0.72
SWAY=0.13
prev=
for a in "$@"; do
    case "$prev" in
        --seconds) SECONDS_TO_RUN=$a ;;
        --fps)     FPS=$a ;;
        --ratio)   RATIO=$a ;;
        --sway)    SWAY=$a ;;
    esac
    case "$a" in
        --hold)        HOLD=1 ;;
        --until-touch) WAIT_TOUCH=1 ;;
    esac
    prev=$a
done

paint_fb_geometry
paint_take_vt

# Always puts the desktop back. A still image left on the glass is a
# photograph waiting to be taken; a moving one left behind is just a console
# nobody can get back.
trap 'paint_restore_vt' EXIT INT TERM

step "Driving a tunnel on the ${W}x${H} panel"
set +e
python3 "$HERE/tools/tunnel.py" \
    --width "$W" --height "$H" --stride "$STRIDE" --bpp "$BPP" \
    --seconds "$SECONDS_TO_RUN" --fps "$FPS" \
    --ratio "$RATIO" --sway "$SWAY" \
    --vt "tty$PAINT_VT" \
    $( [ "$HOLD" = 1 ] && echo --hold ) \
    $( [ "$WAIT_TOUCH" = 1 ] && echo --until-touch )
rc=$?
set -e

case "$rc" in
    0) ok "done" ;;
    3) ok "touched - the touchscreen works on this panel" ;;
    *) warn "tunnel exited with status $rc" ;;
esac

paint_restore_vt

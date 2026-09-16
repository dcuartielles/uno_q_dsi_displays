#!/bin/sh
# A vaporwave landscape, until someone touches the glass.
#
#   sudo ./scripts/show-vaporwave.sh                 # landscape, touch to exit
#   sudo ./scripts/show-vaporwave.sh --rotate 270    # if it comes up inverted
#   sudo ./scripts/show-vaporwave.sh --rotate 0      # compose upright instead
#   sudo ./scripts/show-vaporwave.sh --seconds 120
#
# A purple perspective grid converging on the centre of the image, a wireframe
# sun in bright orange above the horizon, and ARDUINO floating in front of it
# on a travelling sine wave. Touching the screen ends it and hands the console
# back, so the panel returns to the login prompt.
#
# ROTATION
# --------
# Defaults to a quarter turn, because the panel this was written for - the
# Waveshare 8.8inch - is a 480x1920 bar whose framebuffer is tall and narrow.
# A horizon composed into that upright would be a letterbox on its side, so the
# scene is composed 1920x480 and mapped on the way out.
#
# Which quarter turn depends on how the panel is physically mounted, and no
# software here can know that: --rotate 90 and --rotate 270 differ by half a
# turn, so if the picture is upside down, use the other one. --rotate 0 gives
# the scene composed to the framebuffer as it is, for a panel already wider
# than it is tall.
set -e
HERE=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
. "$HERE/lib/common.sh"
. "$HERE/lib/paint.sh"
need_root "$@"

SECONDS_TO_RUN=600
HOLD=0
WAIT_TOUCH=1
FPS=15
ROTATE=90
prev=
for a in "$@"; do
    case "$prev" in
        --seconds) SECONDS_TO_RUN=$a ;;
        --fps)     FPS=$a ;;
        --rotate)  ROTATE=$a ;;
    esac
    case "$a" in
        --hold)     HOLD=1 ;;
        --no-touch) WAIT_TOUCH=0 ;;
    esac
    prev=$a
done

paint_fb_geometry
paint_take_vt

# Always gives the console back, so the panel ends on the login prompt rather
# than on a console nobody can get out of.
trap 'paint_restore_vt' EXIT INT TERM

step "Vaporwave on the ${W}x${H} panel (rotate ${ROTATE})"
set +e
python3 "$HERE/tools/vaporwave.py" \
    --width "$W" --height "$H" --stride "$STRIDE" --bpp "$BPP" \
    --rotate "$ROTATE" --seconds "$SECONDS_TO_RUN" --fps "$FPS" \
    --vt "tty$PAINT_VT" \
    $( [ "$HOLD" = 1 ] && echo --hold ) \
    $( [ "$WAIT_TOUCH" = 1 ] && echo --until-touch )
rc=$?
set -e

case "$rc" in
    0) ok "done" ;;
    3) ok "touched - back to the login prompt" ;;
    *) warn "vaporwave exited with status $rc" ;;
esac

paint_restore_vt

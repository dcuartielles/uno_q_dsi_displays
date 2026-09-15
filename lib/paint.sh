# Shared plumbing for the scripts that paint straight into the framebuffer.
#
# Sourced by scripts/show-spiral.sh and scripts/show-tunnel.sh. It exists
# because getting a console to paint on is the part of those scripts that has
# actually gone wrong - three separate faults, each of which let the write
# succeed while the screen did not change and nothing was logged:
#
#   - the paint VT had a getty on it, whose login prompt painted over the image
#   - the VT was derived from ps output containing TERM=vt220, so chvt 221
#     failed and the write landed on the console X owns and was discarded
#   - lightdm took the console back mid-photograph
#
# One copy of that reasoning is enough. A second copy is a second place for it
# to rot.

# Sets W, H, BPP and STRIDE from the framebuffer, and turns the backlight up.
paint_fb_geometry() {
    [ -e /dev/fb0 ] || die "no /dev/fb0 - the display pipeline is not up"

    W=$(cut -d, -f1 /sys/class/graphics/fb0/virtual_size)
    H=$(cut -d, -f2 /sys/class/graphics/fb0/virtual_size)
    BPP=$(cat /sys/class/graphics/fb0/bits_per_pixel)

    # A framebuffer line is stride bytes, which is not always width * bpp/8 -
    # on a 720-wide panel the kernel pads 2880 up to 2944, and writing the
    # short rows shears the image into something that looks exactly like
    # broken timings.
    STRIDE=$(cat /sys/class/graphics/fb0/stride 2>/dev/null || echo "")
    [ -n "$STRIDE" ] || STRIDE=$(( W * BPP / 8 ))

    _bl=$(ls -d /sys/class/backlight/*/ 2>/dev/null | head -1)
    [ -n "$_bl" ] && { echo 255 > "$_bl/brightness" 2>/dev/null || true; }
    return 0
}

# Takes a console to paint on and arranges to give it back on exit. Sets
# PAINT_VT and BACK_VT. Fatal if the console cannot be taken - painting into
# one someone else owns is discarded in silence, which reads as a dead panel.
paint_take_vt() {
    # Consoles 1..6 get a getty from systemd's autovt the moment you switch to
    # them, and 7 is where X usually sits. Rather than deduce that, check:
    # take the first console above them with no getty running on it.
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

    # fgconsole prints nothing when there is no controlling terminal, which is
    # the case over adb - so its output is checked, not just its exit status.
    BACK_VT=$(fgconsole 2>/dev/null || true)
    case "$BACK_VT" in ''|*[!0-9]*) BACK_VT=7 ;; esac

    have_cmd chvt || die "chvt is not available"

    # chvt returning 0 only means the request was accepted; whether it stuck is
    # a separate question, so confirm it against the active console.
    chvt "$PAINT_VT" 2>/dev/null \
        || die "chvt $PAINT_VT failed - cannot take a console to paint on"
    _t=0
    while [ "$_t" -lt 20 ]; do
        [ "$(cat /sys/class/tty/tty0/active 2>/dev/null)" = "tty$PAINT_VT" ] \
            && break
        _t=$((_t + 1))
        sleep 0.25
    done
    [ "$(cat /sys/class/tty/tty0/active 2>/dev/null)" = "tty$PAINT_VT" ] \
        || die "could not take tty$PAINT_VT - something else holds the console"

    sleep 1
    # No cursor in the photograph, and no console blanking part way through a
    # long wait for someone to fetch a camera.
    if have_cmd setterm; then
        setterm --cursor off > "/dev/tty$PAINT_VT" 2>/dev/null || true
        setterm --blank 0 --powersave off > "/dev/tty$PAINT_VT" 2>/dev/null || true
    fi
    return 0
}

paint_restore_vt() {
    chvt "$BACK_VT" 2>/dev/null || true
}

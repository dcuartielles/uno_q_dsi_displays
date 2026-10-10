#!/bin/sh
# Collect everything a new panel's pull request needs. One command, on the
# board, with the panel attached.
#
#   sudo tools/capture-panel.sh my-panel-name
#
# It writes submissions/<name>/ and prints what to do next. Nothing is sent
# anywhere; you review it and attach it to the pull request yourself.
#
# WHY A SCRIPT RATHER THAN A CHECKLIST
# ------------------------------------
# Because the reviewer does not have your panel, and never will. A pull request
# adding a panel can only be judged on evidence, and the evidence has to be the
# raw answers from the hardware - not a description of them.
#
# The one file that matters most is the touch controller's config dump. It is
# what lets tools/check-fingerprints.py answer, with no hardware at all, the
# question that has gone wrong three times here: does this fingerprint pick out
# one panel, or does it also match somebody else's?
#
# Your dump then protects every panel added after yours, which is the whole
# bargain: contribute the evidence, and the next contributor cannot break your
# panel without CI noticing.
set -e
HERE=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
. "$HERE/lib/common.sh"
need_root "$@"

PANEL=${1:-}
if [ -z "$PANEL" ]; then
    die "usage: sudo tools/capture-panel.sh <panel-id>

    Use the name the definition will have, lowercase with dashes, matching
    how the panel is sold. For example:

        waveshare-5in5-touch-a
        arduino-12in-touch-a

    Keep any fraction in the name if dropping it would collide with another
    panel - the 8.8 inch is waveshare-8in8-touch-a precisely because
    arduino-8in-touch-a is a different panel."
fi

OUT="$HERE/submissions/$PANEL"
mkdir -p "$OUT"
step "Collecting into submissions/$PANEL"

# ------------------------------------------------------------ environment ---
{
    echo "# captured $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    echo "panel-id: $PANEL"
    echo "model: $(tr -d '\0' < /proc/device-tree/model 2>/dev/null)"
    echo "kernel: $(uname -r)"
    echo "arch: $(uname -m)"
    # In a subshell on purpose. /etc/os-release defines NAME, among others,
    # and sourcing it in this one overwrote the panel name - every path after
    # it was then built from "Debian GNU/Linux".
    if [ -r /etc/os-release ]; then
        echo "os: $( . /etc/os-release; printf '%s' "$PRETTY_NAME" )"
    fi
    echo ""
    echo "# carrier"
    arduino-linux-config carrier status 2>&1 | sed 's/^/  /' || echo "  (arduino-linux-config not available)"
    echo ""
    echo "# display overlays this image ships"
    ls /boot/efi/dtb/qcom/*panel* 2>/dev/null | sed 's/^/  /' || echo "  (none found)"
} > "$OUT/environment.txt" 2>&1
ok "environment.txt"

# -------------------------------------------------------------- i2c scan ---
# The scan is the first thing a reviewer reads. It also catches the failure
# that masquerades as an unknown panel: a bus held low answers on every
# address with 0x00, and no fingerprint can be built from that.
sh "$HERE/scripts/detect-panel.sh" --scan > "$OUT/i2c-scan.txt" 2>&1 || true
ok "i2c-scan.txt"
sed -n 's/.*Carrier I2C bus is i2c-\([0-9]*\).*/\1/p' "$OUT/i2c-scan.txt" \
    | head -1 > "$OUT/.bus" 2>/dev/null || true

if grep -q "THE I2C BUS IS NOT WORKING" "$OUT/i2c-scan.txt" 2>/dev/null; then
    say ""
    warn "The I2C bus is not working, so there is nothing to fingerprint yet."
    say "  See submissions/$PANEL/i2c-scan.txt - fix that first."
    say "  docs/TROUBLESHOOTING.md has the causes in order."
    exit 1
fi

# ------------------------------------------------------- touch controller ---
# A Goodix at 0x5d is what every panel here has used so far. If yours is
# something else the dump will be empty, which is fine - say so in the pull
# request and include whatever your controller does answer.
# A dump is real when it has DATA LINES, not when the command exited 0 and
# not when the file contains the characters "0x" - the header says
# "addr=0x5d" whether or not anything answered, and testing for that accepted
# a file of pure comments as a dump.
has_data() {
    [ -s "$1" ] && grep -qE '^[0-9a-f]{4}: *0x' "$1" 2>/dev/null
}

DUMP=
DUMP_KIND=

sh "$HERE/tools/goodix-config.sh" dump "$OUT/goodix-0x5d.txt" >/dev/null 2>&1 || true
if has_data "$OUT/goodix-0x5d.txt"; then
    ok "goodix-0x5d.txt"
    DUMP="$OUT/goodix-0x5d.txt"
    DUMP_KIND=goodix
else
    rm -f "$OUT/goodix-0x5d.txt"
    say "  no Goodix at 0x5d"
fi

# ALWAYS, even when a Goodix was found. Both product lines have a chip at
# 0x45, so a Goodix panel's 0x45 contents are what prove it is not mistaken
# for an LCD-line panel - and without them that pairing cannot be checked in
# either direction.
if i2ctransfer -y -f "$(cat "$OUT/.bus" 2>/dev/null || echo 2)" w1@0x45 0x80 r1 >/dev/null 2>&1; then
    {
        echo "# panel controller at 0x45"
        echo "# addr=0x45 first=0x80 count=16"
        echo "# kernel=$(uname -r)"
        echo "#"
        echo "# BOTH product lines put something here, and they are different"
        echo "# parts: an RPi-style ATTINY on the DSI LCD line, a Waveshare GPIO"
        echo "# chip on the DSI-TOUCH lines. So the address proves nothing and"
        echo "# the CONTENTS are the whole signature - which is also why this is"
        echo "# worth capturing even on a panel detected via its Goodix."
        echo "#"
        echo "# On the ATTINY only REG_ID (0x80) is identity: 0x81-0x83 are"
        echo "# PORTA/PORTB/PORTC, live pin state that drifts."
        for r in 80 81 82 83 84 85 86 87 88 89 8a 8b 8c 8d 8e 8f; do
            v=$(i2ctransfer -y -f "$(cat "$OUT/.bus" 2>/dev/null || echo 2)" \
                    w1@0x45 "0x$r" r1 2>/dev/null)
            printf '00%s: %s\n' "$r" "${v:-unreadable}"
        done
    } > "$OUT/ctrl-0x45.txt"
    if has_data "$OUT/ctrl-0x45.txt"; then
        ok "ctrl-0x45.txt"
        if [ -z "$DUMP" ]; then
            DUMP="$OUT/ctrl-0x45.txt"
            DUMP_KIND=addr-0x45
        fi
    else
        rm -f "$OUT/ctrl-0x45.txt"
    fi
fi

if [ -z "$DUMP" ]; then
    say ""
    warn "No touch controller answered, so there is no signature to record."
    say "  Detection needs something on the bus that identifies this panel."
    say "  Include your i2c-scan.txt in the pull request and say what the"
    say "  panel uses - docs/ADDING-A-PANEL.md section 8 covers the case."
fi

# ------------------------------------------------------------- the panel ---
{
    echo "# DRM connectors"
    for c in /sys/class/drm/card*-DSI-*/; do
        [ -d "$c" ] || continue
        echo "$(basename "$c"): $(cat "$c/status" 2>/dev/null)"
        echo "  modes: $(tr '\n' ' ' < "$c/modes" 2>/dev/null)"
    done
    echo ""
    echo "# framebuffer"
    for f in virtual_size stride bits_per_pixel; do
        [ -r "/sys/class/graphics/fb0/$f" ] && \
            echo "  $f: $(cat "/sys/class/graphics/fb0/$f")"
    done
    echo ""
    echo "# panel / dsi drivers bound"
    for d in /sys/bus/mipi-dsi/drivers/*/; do
        [ -d "$d" ] || continue
        for l in "$d"*; do
            [ -L "$l" ] && echo "  $(basename "$d") <- $(basename "$l")"
        done
    done
    echo ""
    echo "# input devices"
    grep -E '^(N|H|B: ABS)' /proc/bus/input/devices 2>/dev/null | sed 's/^/  /'
} > "$OUT/display.txt" 2>&1
ok "display.txt"

dmesg 2>/dev/null | grep -iE 'dsi|panel|goodix|drm|i2c|cci' | tail -120 \
    > "$OUT/dmesg.txt" 2>&1 || true
ok "dmesg.txt"

# -------------------------------------------------- propose a fingerprint ---
if [ -n "$DUMP" ]; then
    step "Proposing a fingerprint"
    # Compares your panel against every panel anyone has recorded, and picks
    # the shortest chain of reads that separates yours from all of them.
    python3 "$HERE/tools/check-fingerprints.py" \
        --suggest "$DUMP" | tee "$OUT/fingerprint.txt" || true
fi

# -------------------------------------------------------------- the draft ---
DRAFT="$OUT/DRAFT.panel"
if [ ! -f "$DRAFT" ]; then
    {
        echo "# $PANEL - DRAFT, generated by tools/capture-panel.sh"
        echo "#"
        echo "# Fill in the blanks, copy to panels/$PANEL.panel, and read"
        echo "# docs/ADDING-A-PANEL.md for what each field means."
        echo "#"
        echo "# Say WHY, not just what. Every definition here explains the"
        echo "# things that are not obvious from the values - which panels it"
        echo "# is easily confused with, what was measured rather than assumed,"
        echo "# and what is still unverified. That is what makes the next"
        echo "# person's job possible."
        echo ""
        echo "PANEL_ID=\"$PANEL\""
        echo "PANEL_DESC=\"\"                 # e.g. Waveshare 5.5inch DSI-TOUCH-A (720x1280)"
        echo ""
        echo "# Pick one path - see docs/ADDING-A-PANEL.md:"
        echo "#   STOCK_SUPPORT=1   the kernel and Arduino already have it"
        echo "#   DERIVED_PANEL=1   an upstream driver trimmed to this panel"
        echo "#   (neither)         described from scratch in this file"
        echo "DERIVED_PANEL=1"
        echo "STOCK_MODE=\"\"                 # e.g. 720x1280"
        echo ""
        echo "DRIVER_URL=\"https://raw.githubusercontent.com/raspberrypi/linux/rpi-6.12.y/drivers/gpu/drm/panel/panel-waveshare-dsi-v2.c\""
        echo "DRIVER_PATCHER=\"tools/patch-waveshare-panel.py\""
        echo "PANEL_DT_COMPATIBLE=\"\"        # the entry in that driver's match table"
        echo ""
        echo "OVERLAY_TEMPLATE_OPTION=\"10-dsi-touch-a\""
        echo "CARRIER_DISPLAY_OPTION=\"5-dsi-touch-a\""
        echo ""
        echo "RESET_GPIO_LINE=1"
        echo "IOVCC_GPIO_LINE=4"
        echo "AVDD_GPIO_LINE=0"
        echo ""
        echo "TOUCH_ADDR=\"0x5d\""
        echo "TOUCH_SWAP_XY=0"
        echo "TOUCH_INVERT_X=0"
        echo "TOUCH_INVERT_Y=0"
        echo "STOCK_DRIVERS=\"goodix_ts\""
        echo ""
        echo "DETECT_ADDR=\"0x5d\""
        echo "DETECT_NOTE=\"\"                # one line, what the match means"
        if [ -f "$OUT/fingerprint.txt" ]; then
            echo ""
            echo "# --- proposed by capture-panel.sh, check it before trusting it ---"
            sed -n '/^DETECT/p' "$OUT/fingerprint.txt"
        fi
    } > "$DRAFT"
    ok "DRAFT.panel"
fi

# ---------------------------------------------------------------- wrap up ---
say ""
step "Next"
say ""
say "  1. Finish ${C_BLD}submissions/$PANEL/DRAFT.panel${C_OFF} and copy it to"
say "     panels/$PANEL.panel"
say ""
say "  2. Install it and look at the screen:"
say "        sudo ./install.sh panels/$PANEL.panel     # or 16-install-derived-panel.sh"
say "        sudo reboot"
say "        sudo ./scripts/45-confirm-display.sh panels/$PANEL.panel"
say "        sudo ./scripts/show-spiral.sh --until-touch"
say ""
say "     The spiral is the honest test: it proves the panel is still being"
say "     refreshed, not just that one frame was painted - and the touch that"
say "     dismisses it proves the digitizer works on the glass in front of you."
say ""
if [ -n "$DUMP" ]; then
    say "  3. Copy the signature where CI can use it, so it protects your"
    say "     panel against every panel added after yours:"
    say "        mkdir -p bench/results/$DUMP_KIND"
    say "        cp submissions/$PANEL/$(basename "$DUMP") bench/results/$DUMP_KIND/$PANEL.txt"
else
    say "  3. (no signature was captured - see the warning above)"
fi
say ""
say "  4. Check nothing collides:"
say "        python3 tools/check-fingerprints.py -v"
say ""
say "  5. Open the pull request. CONTRIBUTING.md lists what to paste in."
say ""

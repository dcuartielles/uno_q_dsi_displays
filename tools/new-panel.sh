#!/bin/sh
# Bring up a panel this repository does not know yet, and leave a pull request
# behind. One command, a handful of questions.
#
#   sudo tools/new-panel.sh
#   sudo tools/new-panel.sh --restart      # throw away a half-finished run
#
# WHAT THIS IS FOR
# ----------------
# Raspberry Pi's driver carries seventeen Waveshare panels; this repository has
# definitions for seven of them. The other ten are not hard - their mode and
# vendor initialisation sequence are already written - but somebody has to put
# the panel on a bench, find out what its touch controller answers, and write
# it down.
#
# That is what this does. It is the only script here that holds a conversation,
# because two of the steps genuinely cannot be automated: which panel you
# bought, and whether the picture looks right.
#
# WHY THE FINGERPRINT IS NOT GUESSED
# ----------------------------------
# A definition needs two halves. The MODE comes from upstream - no panel
# reports its own timings, because DSI carries no EDID. The FINGERPRINT has to
# come from the panel, and it cannot be inferred from upstream at all: that
# driver describes displays and says nothing about touch controllers.
#
# Which is exactly why this works where a table of "untested" definitions
# would not. The panel is in front of you. Its controller is on the bus. The
# fingerprint is measured, not assumed - and the definition is earned.
#
# IT SPANS A REBOOT
# -----------------
# Installing a panel needs one, because the overlay is merged into the base
# device tree offline. State is kept in submissions/<id>/.state and the script
# picks up where it left off, so run it again after the board comes back.
set -e
HERE=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
. "$HERE/lib/common.sh"
. "$HERE/lib/ask.sh"
need_root "$@"
ask_ready

SUB="$HERE/submissions"

for a in "$@"; do
    case "$a" in
        --restart) rm -rf "$SUB"/*/.state 2>/dev/null || true
                   say "  previous run discarded" ;;
    esac
done

# Resume if a run is part-way through.
STATE=$(ls "$SUB"/*/.state 2>/dev/null | head -1 || true)
if [ -n "$STATE" ]; then
    # shellcheck disable=SC1090
    . "$STATE"
    step "Resuming: $PANEL_NEW_ID"
else
    PHASE=look
fi

# ---------------------------------------------------------------- phase 1 ---
if [ "${PHASE:-look}" = look ]; then

    step "Looking at what is attached"

    # If a definition already matches, there is nothing to add.
    if det=$(sh "$HERE/scripts/detect-panel.sh" 2>/dev/null); then
        known=$(printf '%s' "$det" | sed -n 's/.*Detected: \(.*\)/\1/p' | head -1)
        if [ -n "$known" ]; then
            say ""
            ok "This panel is already supported: $known"
            say ""
            say "  Install it with:"
            say "      sudo ./scripts/detect-panel.sh --apply"
            exit 0
        fi
    fi
    say "  no definition here matches it - good, that is what this is for"

    # The bus, from the scan, the same way capture-panel.sh finds it.
    SCAN=$(sh "$HERE/scripts/detect-panel.sh" --scan 2>&1 || true)
    BUS=$(printf '%s' "$SCAN" | sed -n 's/.*Carrier I2C bus is i2c-\([0-9]*\).*/\1/p' | head -1)
    [ -n "$BUS" ] || die "could not find the carrier I2C bus - see --scan"

    if printf '%s' "$SCAN" | grep -q "THE I2C BUS IS NOT WORKING"; then
        die "the I2C bus is not working, so there is nothing to read yet.
    See docs/TROUBLESHOOTING.md - power and the ribbon cable come first."
    fi

    RES_RAW=$(i2ctransfer -y -f "$BUS" w2@0x5d 0x80 0x48 r4 2>/dev/null || true)
    if [ -z "$RES_RAW" ]; then
        say ""
        warn "No Goodix touch controller answered at 0x5d."
        say ""
        say "  Every panel this wizard can finish has one. Yours may be the"
        say "  LCD line, which is fingerprinted through an ATTINY at 0x45 and"
        say "  reports no resolution - so the mode has to come from the"
        say "  vendor's own driver."
        say ""
        say "  Collect the evidence anyway and open a pull request by hand:"
        say "      sudo tools/capture-panel.sh <your-id>"
        say "      see CONTRIBUTING.md"
        exit 1
    fi

    # Four bytes, two little-endian 16-bit values.
    # shellcheck disable=SC2086
    set -- $RES_RAW
    X=$(( $(printf '%d' "$1") | ($(printf '%d' "$2") << 8) ))
    Y=$(( $(printf '%d' "$3") | ($(printf '%d' "$4") << 8) ))
    ok "the digitizer reports ${X}x${Y}"

    # ------------------------------------------------------------ identify --
    step "Which upstream panel is this?"
    MATCH=$(python3 "$HERE/tools/match-upstream.py" --resolution "${X}x${Y}" 2>&1 || true)
    printf '%s\n' "$MATCH" | sed 's/^/  /'

    CANDS=$(printf '%s' "$MATCH" | sed -n 's/.*\(waveshare,[a-z0-9.,-]*\).*/\1/p' \
            | sort -u)
    NCAND=$(printf '%s' "$CANDS" | grep -c . || true)

    if [ "${NCAND:-0}" -eq 0 ]; then
        say ""
        say "  Nothing upstream has this resolution, so there is no mode to"
        say "  borrow. This panel needs describing from the vendor's own"
        say "  driver - see docs/ADDING-A-PANEL.md. Capturing the evidence is"
        say "  still worth doing:"
        say "      sudo tools/capture-panel.sh <your-id>"
        exit 1
    fi

    if [ "$NCAND" -eq 1 ]; then
        COMPAT=$CANDS
        say ""
        ok "one candidate: $COMPAT"
        ask_yn "Is that the panel you have?" y || \
            die "then this wizard cannot place it - see docs/ADDING-A-PANEL.md"
    else
        say ""
        say "  Several upstream panels share this resolution, and nothing on"
        say "  the panel separates them - the clocks and lane counts differ"
        say "  and neither is readable. You know which one you bought; the"
        say "  size is in the model number."
        say ""
        # shellcheck disable=SC2086
        COMPAT=$(ask_menu "Which is it?" $CANDS)
    fi
    ok "using $COMPAT"

    LANES=$(printf '%s' "$MATCH" | grep -F "$COMPAT" | sed -n 's/.*[^0-9]\([0-9]\) lanes.*/\1/p' | head -1)
    CLOCK=$(python3 "$HERE/tools/match-upstream.py" --list 2>/dev/null \
            | awk -v c="$COMPAT" '$1==c {print $4}' | head -1)

    # ---------------------------------------------------------------- name --
    step "Naming it"
    SUGGEST=$(printf '%s' "$COMPAT" | sed 's/^waveshare,//; s/\./in/; s/-dsi-/-/' \
              | sed 's/^/waveshare-/')
    say "  Lowercase with dashes, the way the other definitions are named."
    say "  Keep any fraction if dropping it would collide - the 8.8 inch is"
    say "  waveshare-8in8-touch-a because arduino-8in-touch-a is different"
    say "  hardware."
    say ""
    ID=$(ask_text "Panel id?" "$SUGGEST")
    [ -n "$ID" ] || die "a name is needed"
    if [ -f "$HERE/panels/$ID.panel" ]; then
        die "panels/$ID.panel already exists. Pick another name, or if you
    are redoing a run, remove it first."
    fi

    DESC=$(ask_text "One-line description?" \
           "$(printf '%s' "$COMPAT" | sed 's/waveshare,/Waveshare /; s/-dsi-touch-/inch DSI-TOUCH-/') (${X}x${Y})")

    # ------------------------------------------------------------- capture --
    step "Capturing the evidence"
    sh "$HERE/tools/capture-panel.sh" "$ID" >/dev/null 2>&1 || true
    OUT="$SUB/$ID"
    [ -f "$OUT/fingerprint.txt" ] || die "capture-panel.sh produced no fingerprint"
    ok "submissions/$ID/"

    # --------------------------------------------------------- the panel ----
    step "Writing panels/$ID.panel"
    MEASURED=$(printf 'touch resolution   %s\nproduct ID / fingerprint   see DETECT_ below' "${X}x${Y}")
    python3 "$HERE/tools/write-panel.py" \
        --id "$ID" --desc "$DESC" --mode "${X}x${Y}" \
        --compatible "$COMPAT" --lanes "${LANES:-?}" --clock "${CLOCK:-?}" \
        --measured "$MEASURED" \
        --fingerprint "$OUT/fingerprint.txt" \
        --out "$HERE/panels/$ID.panel"

    # Before anything is installed: would this definition also match a panel
    # already described here? A fingerprint that matches two panels makes
    # detection stop and ask, which would break a panel that works today -
    # and the person who finds out is not the person who added it.
    step "Checking it collides with nothing"
    if python3 "$HERE/tools/check-fingerprints.py" >/dev/null 2>&1; then
        ok "no collision with any panel recorded here"
    else
        say ""
        python3 "$HERE/tools/check-fingerprints.py" 2>&1 | sed 's/^/  /'
        say ""
        rm -f "$HERE/panels/$ID.panel"
        die "that fingerprint would also match a panel already described here,
    so detection could not tell them apart. The definition has been removed.

    This is worth reporting rather than working around - two panels that
    answer alike is a fact about the hardware. Please open an issue with
    submissions/$ID/ attached."
    fi

    say ""
    say "  Read it before installing - it marks what was measured and what"
    say "  was assumed:"
    say "      less panels/$ID.panel"
    say ""
    ask_yn "Install it now?" y || {
        say "  Stopped. Install it yourself with:"
        say "      sudo ./scripts/16-install-derived-panel.sh panels/$ID.panel"
        exit 0
    }

    step "Installing"
    sh "$HERE/scripts/16-install-derived-panel.sh" "$HERE/panels/$ID.panel"

    {
        echo "PHASE=verify"
        echo "PANEL_NEW_ID=$ID"
        echo "PANEL_NEW_COMPAT=$COMPAT"
        echo "PANEL_NEW_MODE=${X}x${Y}"
    } > "$OUT/.state"

    say ""
    step "Reboot, then run this again"
    say ""
    say "      sudo reboot"
    say "      sudo tools/new-panel.sh"
    say ""
    say "  The overlay is merged into the device tree offline, so nothing"
    say "  changes until the board restarts."
    exit 0
fi

# ---------------------------------------------------------------- phase 2 ---
ID=$PANEL_NEW_ID
OUT="$SUB/$ID"

step "Did it work?"

CONN=$(for c in /sys/class/drm/card*-DSI-*/; do
           [ -d "$c" ] && printf '%s %s %s' "$(basename "$c")" \
               "$(cat "$c/status" 2>/dev/null)" "$(head -1 "$c/modes" 2>/dev/null)"
       done)
FB=$(cat /sys/class/graphics/fb0/virtual_size 2>/dev/null || echo none)
DRV=$(for d in /sys/bus/mipi-dsi/drivers/*/; do
          for l in "$d"*; do
              [ -L "$l" ] && basename "$d"
          done
      done 2>/dev/null | head -1)

say "  connector : ${CONN:-none}"
say "  framebuffer: $FB"
say "  driver    : ${DRV:-none bound}"

if [ "$FB" = none ]; then
    say ""
    warn "No framebuffer, so the panel did not come up."
    say ""
    say "  The most likely cause is the wrong upstream entry - several panels"
    say "  can share a resolution and only one has your timings. See:"
    say "      python3 tools/match-upstream.py --resolution $PANEL_NEW_MODE"
    say ""
    say "  dmesg is in submissions/$ID/dmesg.txt after another capture run."
    echo "PHASE=failed" >> "$OUT/.state"
    exit 1
fi

say ""
say "  Putting a moving pattern on the screen. Look at it."
say ""
sh "$HERE/scripts/show-spiral.sh" --until-touch --seconds 120 >/dev/null 2>&1 || true

say ""
PIC=no; TCH=no
ask_yn "Was the picture correct - no tearing, shear or stepped edges?" y && PIC=yes
ask_yn "Did touching the glass dismiss the pattern?" y && TCH=yes

[ "$PIC" = yes ] || warn "A wrong picture usually means the wrong upstream entry."

# ------------------------------------------------------------ the bundle ---
step "Writing the pull request"

cp "$HERE/panels/$ID.panel" "$OUT/" 2>/dev/null || true
mkdir -p "$HERE/bench/results/goodix"
[ -f "$OUT/goodix-0x5d.txt" ] && \
    cp "$OUT/goodix-0x5d.txt" "$HERE/bench/results/goodix/$ID.txt"
if [ -f "$OUT/ctrl-0x45.txt" ]; then
    mkdir -p "$HERE/bench/results/addr-0x45"
    cp "$OUT/ctrl-0x45.txt" "$HERE/bench/results/addr-0x45/$ID.txt"
fi

PR="$OUT/PULL-REQUEST.md"
{
    echo "## The panel"
    echo ""
    echo "- **Name:** $ID"
    echo "- **Upstream entry:** \`$PANEL_NEW_COMPAT\`"
    echo "- **Resolution:** $PANEL_NEW_MODE"
    echo "- **Integration path:** derived"
    echo "- **Board:** $(tr -d '\0' < /proc/device-tree/model 2>/dev/null), kernel $(uname -r)"
    echo ""
    echo "## Detection"
    echo ""
    echo '```'
    sh "$HERE/scripts/detect-panel.sh" 2>&1 | sed 's/\x1b\[[0-9;]*m//g'
    echo '```'
    echo ""
    echo '```'
    python3 "$HERE/tools/check-fingerprints.py" -v 2>&1 | sed 's/\x1b\[[0-9;]*m//g'
    echo '```'
    echo ""
    echo "## It works"
    echo ""
    echo "- **Connector:** ${CONN:-none}"
    echo "- **Driver bound:** ${DRV:-none}"
    echo "- **Picture correct by eye:** $PIC"
    echo "- **Touch confirmed with a finger:** $TCH"
    echo "- **Photograph:** _attach one - every software check here can pass"
    echo "  while the screen shows garbage_"
    echo ""
    echo "## Honesty"
    echo ""
    echo "Generated by \`tools/new-panel.sh\`. The fingerprint was measured on"
    echo "this panel. The mode, lane count and initialisation sequence come"
    echo "from the upstream entry above and were not independently verified -"
    echo "a DSI panel reports none of them."
    echo ""
    echo "The touch ORIENTATION is unverified unless stated otherwise: the"
    echo "pattern is dismissed by a touch anywhere, which proves the digitizer"
    echo "responds, not that its axes are the right way round."
} > "$PR"

ok "submissions/$ID/PULL-REQUEST.md"

say ""
step "What to send"
say ""
say "  panels/$ID.panel"
say "  bench/results/goodix/$ID.txt"
say "  submissions/$ID/PULL-REQUEST.md   (the description to paste)"
say ""
say "  Nothing has been sent anywhere. The bundle is yours to review first -"
say "  it contains your board's model, kernel and dmesg."
say ""

if ask_yn "Open the pull request now with gh?" n; then
    if have_cmd gh; then
        ( cd "$HERE" && \
          git checkout -b "panel/$ID" 2>/dev/null || true
          git add "panels/$ID.panel" "bench/results/goodix/$ID.txt" 2>/dev/null
          git commit -q -m "panels: add $ID" 2>/dev/null || true
          gh pr create --title "panels: add $ID" --body-file "$PR" ) || \
            warn "gh could not open it - send the files by hand"
    else
        warn "gh is not installed. Send the files by hand, or install it:"
        say "      https://cli.github.com"
    fi
else
    say "  Fine - the files are there when you want them."
fi

rm -f "$OUT/.state"
say ""
ok "done"

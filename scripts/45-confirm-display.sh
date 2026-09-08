#!/bin/sh
# Look at the screen and say whether it is right.
#
#   sudo ./scripts/45-confirm-display.sh panels/<panel>.panel
#   sudo ./scripts/45-confirm-display.sh panels/<panel>.panel --yes   # scripted
#
# Why a human step survives in an otherwise automatic install
# ----------------------------------------------------------
# Every software check can pass while the screen is wrong. That is the whole
# subject of this repository, and it has now happened twice in two different
# ways:
#
#   - the backlight write is lost and the panel is DARK, while DRM reports a
#     connected connector scanning out a framebuffer;
#   - the panel is driven with another panel's timings and the picture is
#     GARBLED, while the connector, the mode, the driver and dmesg are all
#     exactly what they should be.
#
# In the second case 40-verify.sh printed "everything checks out" at a screen
# showing vertical banding. No software check on the board caught it, and none
# can: the framebuffer contents are correct either way, and nothing downstream
# of the DSI link reports back.
#
# So this asks. It takes ten seconds, it is the only check that actually looks
# at the display, and when the answer is "no" it does something useful with it
# rather than leaving you to work out what to try next.
set -e
HERE=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
. "$HERE/lib/common.sh"
need_root "$@"

PANEL_DEF=${1:?usage: $0 <panel definition> [--yes]}
[ -f "$PANEL_DEF" ] || die "no such panel definition: $PANEL_DEF"
PANEL_DEF=$(abspath "$PANEL_DEF")
ASSUME=${2:-}

load_panel "$PANEL_DEF"

# Remember where the desktop is BEFORE anything switches away from it, and put
# it back however this exits.
BACK_VT=$(fgconsole 2>/dev/null || echo 7)
restore_desktop() { chvt "$BACK_VT" 2>/dev/null || true; }
trap restore_desktop EXIT INT TERM

step "Showing a test pattern on $PANEL_ID"
say "  Look at the panel now."
# --hold leaves the pattern up while the question is asked. Without it the
# desktop returns immediately and you would be judging a screen you cannot see.
sh "$HERE/scripts/test-display.sh" --hold >/dev/null 2>&1 ||
    warn "could not paint the framebuffer - is the display up?"

say ""
say "  You should see clean, evenly divided colour bars filling the screen."
say ""
say "  ${C_BLD}Wrong${C_OFF} looks like: vertical banding, the picture repeated or"
say "  shifted sideways, bars of unequal width, or a dark screen."

# ------------------------------------------------------------------ asking --
if [ "$ASSUME" = "--yes" ]; then
    ok "assuming yes (--yes)"
    answer=y
else
    say ""
    printf 'Does the screen look right? [y/N] '
    # A pipe is a fine way to answer; what must never happen is treating "no
    # input at all" as a yes, because that is how a wrong panel ships. read
    # fails on EOF, and that case is reported rather than guessed.
    if ! read -r answer; then
        say ""
        warn "nothing to read an answer from. Run this by hand, or pass --yes"
        warn "if you have already looked at the screen:"
        say "    sudo ./scripts/45-confirm-display.sh \"$PANEL_DEF\""
        exit 2
    fi
fi

case "$answer" in
    y|Y|yes|YES)
        record_state "display confirmed by eye for $PANEL_ID"
        say ""
        ok "confirmed - $PANEL_ID is correct for this panel"
        say ""
        say "The desktop is back."
        exit 0
        ;;
esac

# ------------------------------------------------------------ what to try ---
# A wrong picture on a panel that otherwise works nearly always means the right
# family was found and the wrong member of it chosen. Offer exactly those, so
# the next step is a command to run rather than a puzzle.
say ""
step "Then this is probably the wrong panel definition"

FAMILY=$(
    # shellcheck disable=SC1090
    ( . "$PANEL_DEF"; printf '%s' "${DETECT_EXPECT:-}" )
)

alts=
for p in "$HERE"/panels/*.panel; do
    [ -f "$p" ] || continue
    case "${p##*/}" in TEMPLATE.panel) continue ;; esac
    # shellcheck disable=SC1090
    pid=$( . "$p"; printf '%s' "${PANEL_ID:-}" )
    [ "$pid" = "$PANEL_ID" ] && continue
    # shellcheck disable=SC1090
    pfam=$( . "$p"; printf '%s' "${DETECT_EXPECT:-}" )
    [ -n "$FAMILY" ] && [ "$pfam" != "$FAMILY" ] && continue
    # shellcheck disable=SC1090
    pdesc=$( . "$p"; printf '%s' "${PANEL_DESC:-}" )
    say "    ${C_BLD}$pid${C_OFF}${pdesc:+  - $pdesc}"
    alts="$alts $pid"
done

if [ -z "$alts" ]; then
    say "  No other definition here shares this panel's signature."
    say ""
    say "  Dump the touch controller's config and compare it with the ones in"
    say "  bench/results/goodix/ - that is how the 8 inch and 10.1 inch were"
    say "  eventually told apart:"
    say ""
    say "      sudo ./tools/goodix-config.sh dump mine.txt"
    say ""
    say "  Then see docs/ADDING-A-PANEL.md."
    exit 1
fi

say ""
say "Try one of these, then reboot and run this again:"
say ""
for a in $alts; do
    say "    sudo ./scripts/detect-panel.sh --select $a && sudo reboot"
done
exit 1

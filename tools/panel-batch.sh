#!/bin/sh
# Test a run of panels, one command each. Runs on the HOST, drives the board
# over ADB.
#
#   tools/panel-batch.sh              # test the panel that is plugged in now
#   tools/panel-batch.sh --reset      # start numbering again at 1
#   tools/panel-batch.sh --list       # what has been tested so far
#   tools/panel-batch.sh --no-ask     # stop after the touch, ask nothing
#
# What it does per panel
# ----------------------
#   1. detect what is plugged in, from the touch controller
#   2. install it, which also repairs a hijacked overlay slot
#   3. reboot and wait
#   4. check the display pipeline came up
#   5. paint an INCREASING NUMBER on the screen
#   6. ask whether that number is there and the picture is clean
#
# Step 5 is the point. A colour-bar test looks identical on every panel in a
# batch - including on the one you already tested, if the new panel never came
# up and you are looking at a screen that simply never changed. A number that
# goes up is proof the picture in front of you was drawn for THIS panel.
#
# Step 6 is a human, deliberately. Nothing on the board can see the picture:
# a dark panel, a garbled one and a working one are indistinguishable to every
# software check here. That is the subject of this whole repository.
#
# Step 2 matters more than it looks. Installing a described or derived panel
# puts its overlay into Arduino's 5-inch slot, and a stock panel plugged in
# afterwards is then driven with the wrong timings - it blinks, or shows
# nothing, and looks like a faulty panel. Running the install repairs that from
# the backup automatically. It is why this is not just "reboot and look".
set -eu

HERE=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
BOARD_REPO=/home/arduino/uno-q-dsi-panel
STATE="$HERE/.panel-batch"
RESULTS="$HERE/bench/results/panel-batch.log"

SECRETS=${UNOQ_SECRETS:-$HOME/.unoq-secrets.txt}
SERIAL=""
ACTION=test
ASK=1
TOUCH_TIMEOUT=${TOUCH_TIMEOUT:-300}

while [ $# -gt 0 ]; do
    case "$1" in
        --no-ask) ASK=0 ;;
        --reset)  ACTION=reset ;;
        --list)   ACTION=list ;;
        --serial) SERIAL=$2; shift ;;
        -h|--help) sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "unknown option: $1" >&2; exit 2 ;;
    esac
    shift
done

if [ -t 1 ]; then
    B=$(printf '\033[1m'); G=$(printf '\033[32m'); Y=$(printf '\033[33m')
    R=$(printf '\033[31m'); C=$(printf '\033[36m'); N=$(printf '\033[0m')
else
    B=; G=; Y=; R=; C=; N=
fi
step() { printf '\n%s==> %s%s\n' "$B$C" "$*" "$N"; }
ok()   { printf '%s  ok%s  %s\n' "$G" "$N" "$*"; }
warn() { printf '%s  !!%s  %s\n' "$Y" "$N" "$*"; }
die()  { printf '%s ERROR%s %s\n' "$R" "$N" "$*" >&2; exit 1; }

case "$ACTION" in
  reset) rm -f "$STATE"; echo "numbering reset - the next panel will be 1"; exit 0 ;;
  list)
    [ -f "$RESULTS" ] || { echo "no panels tested yet"; exit 0; }
    printf '%s\n' "$B  #   result        touch    panel                    when$N"
    cat "$RESULTS"
    exit 0 ;;
esac

command -v adb >/dev/null 2>&1 || die "adb is not installed"
# Wait rather than give up: the board is very often mid-reboot when this runs,
# because the person swapping panels has just powered it back on. Dying at that
# instant makes a timing accident look like a missing board.
if [ -z "$SERIAL" ]; then
    _w=0
    while [ "$_w" -lt 40 ]; do
        SERIAL=$(adb devices | awk '/device$/{print $1; exit}')
        [ -n "$SERIAL" ] && break
        [ "$_w" = 0 ] && printf 'waiting for the board over ADB'
        printf '.'
        _w=$((_w + 1)); sleep 3
    done
    [ "$_w" = 0 ] || printf '
'
fi
[ -n "$SERIAL" ] || die "no board found over ADB after two minutes.
    Is it powered and the USB cable in?"
ADB="adb -s $SERIAL"

[ -f "$SECRETS" ] || die "no secrets file at $SECRETS (needs SUDO_PASS=...)"
PW=$(grep -m1 '^SUDO_PASS=' "$SECRETS" | cut -d= -f2- | tr -d '\r\n')
[ -n "$PW" ] || die "no SUDO_PASS in $SECRETS"

# Every command reaches the board the same way, and the password only ever
# travels on stdin - never on a command line, where it would land in ps output
# and in the shell history of whoever is watching.
board() { printf '%s\n' "$PW" | $ADB shell "sudo -S -p '' $1" 2>&1 | tr -d '\r'; }

NUM=1
[ -f "$STATE" ] && NUM=$(( $(cat "$STATE") + 1 ))

printf '%s\n' "$B========================================================$N"
printf '%s\n' "$B  panel #$NUM   board $SERIAL$N"
printf '%s\n' "$B========================================================$N"

# ------------------------------------------------------------------ detect ---
step "Identifying the panel"
det=$(board "sh -c 'cd $BOARD_REPO && ./scripts/detect-panel.sh'" || true)
PANEL=$(printf '%s\n' "$det" | sed -n 's|^  definition: ||p' | head -1)

if [ -z "$PANEL" ]; then
    printf '%s\n' "$det" | sed 's/^/    /' | tail -12
    die "could not identify the panel.
    If two matched, they are indistinguishable on the bus and you must choose:
        adb -s $SERIAL shell 'cd $BOARD_REPO && sudo ./scripts/detect-panel.sh --select <id>'
    If none did, run --scan and see docs/ADDING-A-PANEL.md."
fi
ok "detected $PANEL"

# ----------------------------------------------------------------- install ---
step "Installing it"
# Also repairs the overlay slot if a previous panel's definition displaced it.
out=$(board "sh -c 'cd $BOARD_REPO && ./install.sh $PANEL'" || true)
printf '%s\n' "$out" | grep -E "restored|already|ok  |ERROR" | sed 's/^/    /' | tail -6
printf '%s\n' "$out" | grep -q "ERROR" && die "install failed - see the output above"

# ------------------------------------------------------------------ reboot ---
step "Rebooting"
board "systemctl reboot" >/dev/null 2>&1 || true
sleep 20
# stdin is closed off for every adb call that does not need it: adb shell
# reads its stdin to EOF, so an answer piped into this script gets
# swallowed here and the prompt below sees nothing.
$ADB wait-for-device >/dev/null 2>&1 </dev/null || true
i=0
while [ "$i" -lt 30 ]; do
    up=$($ADB shell 'cut -d. -f1 < /proc/uptime' 2>/dev/null </dev/null | tr -d '\r ')
    case "$up" in ''|*[!0-9]*) up=0 ;; esac
    [ "$up" -ge 25 ] && break
    i=$((i + 1)); sleep 4
done
ok "back up"

# ------------------------------------------------------------------ verify ---
step "Checking the display pipeline"
ver=$(board "sh -c 'cd $BOARD_REPO && ./scripts/40-verify.sh $PANEL'" || true)
printf '%s\n' "$ver" | grep -E "^  ok|^ FAIL|FAIL " | sed 's/^/    /'
FAILED=$(printf '%s\n' "$ver" | grep -c "FAIL" || true)

# ------------------------------------------------------------- the number ---
# Held until the screen is touched, so there is time to photograph it - and so
# that dismissing it doubles as the touch test. The board reports its own exit
# status through a sentinel, because board() pipes its output and $? would
# otherwise be tr's.
step "Painting $NUM on the panel"
printf '\n%sPhotograph the panel now, then TOUCH IT to continue.%s\n\n' "$B" "$N"
res=$(board "sh -c 'cd $BOARD_REPO && ./scripts/show-number.sh $NUM --until-touch --timeout $TOUCH_TIMEOUT; echo RC=\$?'")
printf '%s\n' "$res" | grep -E "^  ok|^  !!" | sed 's/^/  /'
TOUCH_RC=$(printf '%s\n' "$res" | sed -n 's/^RC=//p' | tail -1)
case "${TOUCH_RC:-1}" in
    0) TOUCH="works" ;;
    2) TOUCH="no-input-device" ;;
    *) TOUCH="untouched" ;;
esac

# --------------------------------------------------------------- the human ---
# Touch has answered for itself by now. What is left is whether the picture was
# right, which no software here can see.
printf '\n%sThe number is gone. One question about what you saw.%s\n' "$B" "$N"
printf '  It should have been a large white %s%s%s on black, clean and centred.\n' \
    "$B" "$NUM" "$N"
printf '  Wrong looks like: blinking, banding, a shifted or repeated image,\n'
printf '  a dark screen, or a DIFFERENT number - which would mean this panel\n'
printf '  never came up and you were looking at the previous one.\n\n'

if [ "$ASK" = "1" ]; then
    # A pipe is a perfectly good way to answer this; what must never happen is
    # treating "no input at all" as a pass. read fails only on EOF.
    printf 'Does panel #%s show "%s" cleanly? [y/N] ' "$NUM" "$NUM"
    if read -r answer; then
        printf '\n'
    else
        answer=""
        printf '\n'
        warn "nothing to read an answer from - recording as unconfirmed"
    fi
else
    # The person swapping panels has the photograph and their own eyes; the
    # verdict recorded here is what the board can actually attest to.
    answer=""
fi

board "sh -c 'chvt 7'" >/dev/null 2>&1 </dev/null || true

case "$answer" in
    y|Y|yes|YES) verdict="PASS" ;;
    "")          verdict="UNCONFIRMED" ;;
    *)           verdict="FAIL" ;;
esac
# With --no-ask nobody was asked, so say what was actually established rather
# than "unconfirmed", which would understate a panel that answered a touch.
if [ "$ASK" = "0" ] && [ "$verdict" = "UNCONFIRMED" ]; then
    case "$TOUCH" in
        works) verdict="TOUCH-OK" ;;
        *)     verdict="FAIL(touch)" ;;
    esac
fi
# A panel whose display is right but whose touch never answered is not a pass.
# Recording it as one is how a half-working panel ships.
[ "$verdict" = "PASS" ] && [ "$TOUCH" != "works" ] && verdict="FAIL(touch)"
[ "$FAILED" -gt 0 ] && [ "$verdict" = "PASS" ] && verdict="PASS(sw-warn)"

mkdir -p "$(dirname "$RESULTS")"
printf '  %-3s %-13s %-8s %-24s %s\n' "$NUM" "$verdict" "$TOUCH" \
    "$(basename "$PANEL" .panel)" "$(date '+%Y-%m-%d %H:%M')" >> "$RESULTS"
printf '%s' "$NUM" > "$STATE"

step "Panel #$NUM: $verdict"
say_next() {
    printf '\n%s\n' "Unplug this panel, plug in the next one, and run:"
    printf '%s\n\n' "    tools/panel-batch.sh"
}
case "$verdict" in
    PASS*|TOUCH-OK) ok "recorded in bench/results/panel-batch.log"; say_next ;;
    FAIL)  warn "recorded as FAIL"
           printf '\n%s\n' "If the number was wrong or the screen blinked, check the overlay slot:"
           printf '%s\n' "    adb -s $SERIAL shell 'strings /boot/efi/dtb/qcom/*5in_touch_a-dsi.dtbo | grep waveshare,'"
           printf '%s\n\n' "It should name the panel you just installed, not another one."
           ;;
    *)     warn "recorded as UNCONFIRMED - nobody looked at the screen" ;;
esac

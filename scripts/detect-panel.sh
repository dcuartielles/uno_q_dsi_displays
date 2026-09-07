#!/bin/sh
# Work out which DSI panel is plugged in, and select it.
# Runs ON the board - drive it over ssh or adb.
#
#   sudo ./scripts/detect-panel.sh                  # identify what is connected
#   sudo ./scripts/detect-panel.sh --apply          # identify it, then install it
#   sudo ./scripts/detect-panel.sh --select <id>    # skip detection, pick by hand
#   sudo ./scripts/detect-panel.sh --scan           # dump the bus (unknown panel)
#        ./scripts/detect-panel.sh --list           # what this repo knows about
#
# How it identifies a panel
# -------------------------
# DSI panels carry no EDID, so there is nothing to ask them. What they do have
# is a touch/power controller on the carrier's I2C bus, and those differ per
# panel and answer with NO overlay loaded - verified on a board set to
# display=none, where the Goodix at 0x5d still returned its product ID while
# 0x38 correctly NAKed. That is what makes this usable on a fresh board, before
# anything has been configured, which is when you actually need it.
#
# Each panels/*.panel file carries its own fingerprint:
#
#   DETECT_ADDR      the I2C address that identifies this panel
#   DETECT_WRITE     bytes to write first, e.g. "0x81 0x40" to address a
#                    register (omit for a plain read)
#   DETECT_READ      how many bytes to read back (default 1)
#   DETECT_EXPECT    expected start of the reply, e.g. "0x39 0x31 0x31".
#                    Several alternatives may be separated by "|".
#                    Omit to accept any ACK - presence alone is the signal.
#
# Adding a panel is therefore one .panel file. Run --scan with the new panel
# connected and it prints what answered, ready to turn into a fingerprint.
set -e
HERE=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
. "$HERE/lib/common.sh"

ACTION=detect
SELECT_ID=
while [ $# -gt 0 ]; do
    case "$1" in
        --apply)  ACTION=apply ;;
        --scan)   ACTION=scan ;;
        --list)   ACTION=list ;;
        --select) ACTION=select; SELECT_ID=${2:?--select needs a panel id}; shift ;;
        --select=*) ACTION=select; SELECT_ID=${1#--select=} ;;
        -h|--help) sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) die "unknown option: $1  (try --help)" ;;
    esac
    shift
done

# Panel definitions, minus the template. Printed one per line.
panel_files() {
    for _p in "$HERE"/panels/*.panel; do
        [ -f "$_p" ] || continue
        case "${_p##*/}" in TEMPLATE.panel) continue ;; esac
        printf '%s\n' "$_p"
    done
}

# Read one field out of a .panel in a subshell, so definitions cannot leak into
# each other or into this script.
panel_field() {
    # shellcheck disable=SC1090
    ( . "$1"; eval "printf '%s' \"\${$2:-}\"" )
}

# ------------------------------------------------------------------- list ---
if [ "$ACTION" = list ]; then
    step "Panels this repository knows about"
    for p in $(panel_files); do
        id=$(panel_field "$p" PANEL_ID)
        stock=$(panel_field "$p" STOCK_SUPPORT)
        addr=$(panel_field "$p" DETECT_ADDR)
        note=$(panel_field "$p" DETECT_NOTE)
        say ""
        say "  $C_BLD$id$C_OFF"
        if [ "$stock" = 1 ]; then
            say "    supported by the stock kernel and Arduino overlay"
        else
            say "    needs the patched drivers this repository builds"
        fi
        if [ -n "$addr" ]; then
            say "    detected by: $addr${note:+  ($note)}"
        else
            say "    detected by: nothing declared - select this one by hand"
        fi
        say "    select with: sudo ./scripts/detect-panel.sh --select $id"
    done
    exit 0
fi

# ----------------------------------------------------------------- select ---
# Manual selection touches no I2C at all, so it works with nothing plugged in.
if [ "$ACTION" = select ]; then
    PANEL_FILE=
    for p in $(panel_files); do
        [ "$(panel_field "$p" PANEL_ID)" = "$SELECT_ID" ] || continue
        PANEL_FILE=$p
        break
    done
    [ -n "$PANEL_FILE" ] || die "no panel definition with PANEL_ID \"$SELECT_ID\".
    Run --list to see the ones this repository knows about."
    step "Installing $SELECT_ID"
    exec sh "$HERE/install.sh" "$PANEL_FILE"
fi

need_root "$@"
have_cmd i2ctransfer || die "i2c-tools is not installed:  sudo apt-get install i2c-tools"

# --------------------------------------------------------------- the bus ---
# The carrier's I2C hangs off the Qualcomm CCI controller. Bus numbering is not
# stable - the same board has shown it as 0, 1 and 2 - so find it, never assume.
find_bus() {
    for d in /sys/class/i2c-adapter/i2c-*; do
        [ -e "$d" ] || continue
        n=${d##*/i2c-}
        case "$(cat "$d/name" 2>/dev/null)" in
            *cci*|*CCI*) printf '%s' "$n"; return ;;
        esac
    done
    # Fall back on probing: the carrier's own GPIO expander at 0x26 is there
    # whether or not a panel is, so the bus that answers at 0x26 is the one.
    for n in 0 1 2 3 4 5; do
        [ -e "/dev/i2c-$n" ] || continue
        if i2ctransfer -y -f "$n" r1@0x26 >/dev/null 2>&1; then
            printf '%s' "$n"; return
        fi
    done
}

BUS=$(find_bus)
[ -n "$BUS" ] || die "could not find the carrier's I2C bus.
    Is the media carrier attached, and is i2c-dev loaded?"

# probe <addr> <write-bytes> <read-len>  ->  prints the reply, or fails.
#
# -f is needed because a bound driver marks its address busy; the transfer is
# still safe. Nothing here writes anything except the register address a
# fingerprint asks to read from.
probe() {
    _a=$1; _w=$2; _n=${3:-1}
    if [ -n "$_w" ]; then
        # shellcheck disable=SC2086
        set -- $_w
        # shellcheck disable=SC2086
        i2ctransfer -y -f "$BUS" "w$#@$_a" "$@" "r$_n" 2>/dev/null
    else
        i2ctransfer -y -f "$BUS" "r$_n@$_a" 2>/dev/null
    fi
}

# ------------------------------------------------------------------- scan ---
if [ "$ACTION" = scan ]; then
    step "Carrier I2C bus is i2c-$BUS"
    if have_cmd i2cdetect; then
        say "  UU means a driver has already claimed that address - it is still there."
        say ""
        i2cdetect -y -r "$BUS" 2>/dev/null | sed 's/^/  /'
    fi

    step "Addresses that answer a read"
    found=
    for a in 0x14 0x26 0x38 0x39 0x45 0x4a 0x5a 0x5d; do
        r=$(probe "$a" "" 1) || continue
        say "  $a  ->  $r"
        found="$found $a"
    done
    [ -n "$found" ] || warn "nothing answered - is the panel connected and powered?"

    say ""
    say "To teach this repository a new panel, copy panels/TEMPLATE.panel and give"
    say "it a fingerprint built from an address unique to that panel:"
    say ""
    say "    DETECT_ADDR=\"0x5d\""
    say "    DETECT_WRITE=\"0x81 0x40\"      # register to read; omit for a plain read"
    say "    DETECT_READ=\"4\""
    say "    DETECT_EXPECT=\"0x39 0x31 0x31\""
    say ""
    say "Pick something that tells panels apart, not merely something present:"
    say "0x45 answers on both panels known here, but with different contents."
    exit 0
fi

# ----------------------------------------------------------------- detect ---
step "Looking for a known panel on i2c-$BUS"

MATCHES=
for p in $(panel_files); do
    id=$(panel_field "$p" PANEL_ID)
    addr=$(panel_field "$p" DETECT_ADDR)
    if [ -z "$addr" ]; then
        say "  $id: no fingerprint declared, skipped"
        continue
    fi
    wr=$(panel_field "$p" DETECT_WRITE)
    rl=$(panel_field "$p" DETECT_READ); rl=${rl:-1}
    want=$(panel_field "$p" DETECT_EXPECT)

    if ! got=$(probe "$addr" "$wr" "$rl"); then
        say "  $id: nothing at $addr"
        continue
    fi

    if [ -z "$want" ]; then
        ok "$id: $addr answers"
        MATCHES="$MATCHES $p"
        continue
    fi

    # DETECT_EXPECT may list alternatives separated by "|" - some controllers
    # legitimately report more than one ID.
    hit=0
    _rest=$want
    while [ -n "$_rest" ]; do
        case "$_rest" in
            *"|"*) _alt=${_rest%%|*}; _rest=${_rest#*|} ;;
            *)     _alt=$_rest;       _rest= ;;
        esac
        case "$got" in "$_alt"*) hit=1; break ;; esac
    done

    if [ "$hit" = 1 ]; then
        ok "$id: $addr replied $got"
        MATCHES="$MATCHES $p"
    else
        say "  $id: $addr replied $got, wanted $want"
    fi
done

# shellcheck disable=SC2086
set -- $MATCHES
case $# in
  0)
    say ""
    die "no known panel recognised.
    Run --scan to see what is actually on the bus, then add a panels/*.panel
    file with a DETECT_ block for it. --list shows what is already known, and
    --select <id> installs one by hand if you know which it is."
    ;;
  1) PANEL_FILE=$1 ;;
  *)
    say ""
    warn "more than one panel matched:"
    for m in "$@"; do say "    $(panel_field "$m" PANEL_ID)"; done
    die "their fingerprints do not tell them apart. Make DETECT_EXPECT stricter,
    or choose with --select <id>."
    ;;
esac

FOUND_ID=$(panel_field "$PANEL_FILE" PANEL_ID)
say ""
step "Detected: $FOUND_ID"
say "  definition: panels/${PANEL_FILE##*/}"
FOUND_NOTE=$(panel_field "$PANEL_FILE" DETECT_NOTE)
[ -n "$FOUND_NOTE" ] && say "  matched on: $FOUND_NOTE"

if [ "$ACTION" != apply ]; then
    say ""
    say "To install it:"
    say "    sudo ./scripts/detect-panel.sh --apply"
    say "or equivalently"
    say "    sudo ./install.sh panels/${PANEL_FILE##*/}"
    exit 0
fi

say ""
exec sh "$HERE/install.sh" "$PANEL_FILE"

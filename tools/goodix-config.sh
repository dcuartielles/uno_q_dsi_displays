#!/bin/sh
# Dump a Goodix touch controller's configuration block, and diff two dumps.
#
#   sudo tools/goodix-config.sh dump                     # to stdout
#   sudo tools/goodix-config.sh dump 10in.txt            # to a file
#        tools/goodix-config.sh diff 8in.txt 10in.txt
#
# What this is for
# ----------------
# Two panels can be identical everywhere detect-panel.sh looks and still need
# different overlays. The Arduino 8inch and 10.1inch DSI-TOUCH-A are: same
# Goodix product ID 9271, same config version, same touch resolution, same
# panel driver, same DRM mode - and a garbled picture if you pick the wrong
# one, with every software check still passing.
#
# The product ID is only four bytes of a much larger config block. The rest
# holds panel-specific tuning - sensor and driver channel counts, thresholds,
# per-channel tables - and a digitizer of a different physical size has good
# reason to differ somewhere in there. If it does, that difference can become a
# DETECT_ fingerprint and the guesswork disappears.
#
# If it does NOT differ, that is worth knowing too, and worth recording: it
# turns "we have not looked" into "we looked, and the panels are genuinely
# indistinguishable", which is the difference between an open question and a
# documented limitation.
#
# Why the block is read in small pieces
# -------------------------------------
# Reading all ~190 bytes in one transfer fails on this hardware with
# "Operation not supported". That is not a permissions problem and not a
# missing feature - it is the Qualcomm CCI controller's transfer-size limit,
# the same one that forced the short-read patch in edt-ft5x06. Eight bytes at a
# time works fine. Mistaking that error for a dead end is why this was not
# checked sooner.
set -eu

ADDR=${GOODIX_ADDR:-0x5d}
FIRST=0x8047          # config version, the first byte of the block
COUNT=${GOODIX_COUNT:-192}
STEP=8                # what CCI will carry in one go

usage() {
    sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'
    exit "${1:-0}"
}

find_bus() {
    for d in /sys/class/i2c-adapter/i2c-*; do
        [ -e "$d" ] || continue
        case "$(cat "$d/name" 2>/dev/null)" in
            *cci*|*CCI*) printf '%s' "${d##*/i2c-}"; return ;;
        esac
    done
    for n in 0 1 2 3 4 5; do
        [ -e "/dev/i2c-$n" ] || continue
        i2ctransfer -y -f "$n" r1@0x26 >/dev/null 2>&1 && { printf '%s' "$n"; return; }
    done
}

do_dump() {
    out=${1:-}
    command -v i2ctransfer >/dev/null 2>&1 \
        || { echo "i2c-tools is not installed" >&2; exit 2; }
    [ "$(id -u)" -eq 0 ] || { echo "run this with sudo" >&2; exit 2; }

    bus=$(find_bus)
    [ -n "$bus" ] || { echo "could not find the carrier I2C bus" >&2; exit 2; }

    # Bus numbering is not stable across boots on this hardware, so it is found
    # rather than assumed - and recorded, because a dump is worthless if you
    # cannot tell which bus and address it came from.
    {
        echo "# goodix config block"
        echo "# addr=$ADDR bus=i2c-$bus first=$FIRST count=$COUNT"
        echo "# id=$(i2ctransfer -y -f "$bus" w2@"$ADDR" 0x81 0x40 r4 2>/dev/null || echo unreadable)"
        echo "# kernel=$(uname -r)"
        i=0
        while [ "$i" -lt "$COUNT" ]; do
            hi=$(printf '0x%02x' $(( (0x8047 + i) / 256 )))
            lo=$(printf '0x%02x' $(( (0x8047 + i) % 256 )))
            n=$((COUNT - i)); [ "$n" -gt "$STEP" ] && n=$STEP
            line=$(i2ctransfer -y -f "$bus" w2@"$ADDR" "$hi" "$lo" "r$n" 2>/dev/null) || break
            printf '%04x: %s\n' $((0x8047 + i)) "$line"
            i=$((i + STEP))
        done
    } > "${out:-/dev/stdout}"

    [ -n "$out" ] && echo "wrote $out"
    return 0
}

do_diff() {
    a=${1:?usage: $0 diff <a> <b>}
    b=${2:?usage: $0 diff <a> <b>}
    for f in "$a" "$b"; do
        [ -f "$f" ] || { echo "no such dump: $f" >&2; exit 2; }
    done

    # Compare only the data lines; the headers differ by bus and kernel and
    # would drown the answer in noise that means nothing.
    ta=$(mktemp); tb=$(mktemp)
    grep -v '^#' "$a" > "$ta"; grep -v '^#' "$b" > "$tb"

    if cmp -s "$ta" "$tb"; then
        echo "IDENTICAL - these two panels cannot be told apart by their Goodix"
        echo "config either. Selecting between them has to stay a human choice."
        rm -f "$ta" "$tb"
        return 0
    fi

    echo "THEY DIFFER - a fingerprint is possible. Differing rows:"
    echo
    printf '%-8s %-26s %s\n' "offset" "$(basename "$a")" "$(basename "$b")"
    # shellcheck disable=SC2094
    paste "$ta" "$tb" | while IFS="$(printf '\t')" read -r la lb; do
        [ "$la" = "$lb" ] && continue
        off=${la%%:*}
        printf '%-8s %-26s %s\n' "$off" "${la#*: }" "${lb#*: }"
    done
    echo
    echo "Turn the first stable difference into a DETECT_ block, e.g. for a byte"
    echo "at 0x8053:"
    echo
    echo "    DETECT_ADDR=\"$ADDR\""
    echo "    DETECT_WRITE=\"0x80 0x53\""
    echo "    DETECT_READ=\"1\""
    echo "    DETECT_EXPECT=\"<the value for THIS panel>\""
    echo
    echo "Confirm it is stable across reboots before trusting it - some config"
    echo "bytes are calibration state, not identity."
    rm -f "$ta" "$tb"
}

case "${1:-}" in
    dump) shift; do_dump "${1:-}" ;;
    diff) shift; do_diff "$@" ;;
    -h|--help|"") usage 0 ;;
    *) echo "unknown command: $1" >&2; usage 2 ;;
esac

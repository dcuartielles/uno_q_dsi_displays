#!/bin/sh
# Report how far an OS update has got, as a percentage. Runs on the HOST.
#
#   tools/update-progress.sh                    # one reading
#   tools/update-progress.sh --watch            # keep refreshing
#   tools/update-progress.sh --ssh              # board over SSH instead of ADB
#
# apt gives no overall percentage, but it does say up front how many packages
# it intends to touch, and then names each one as it unpacks and configures it.
# Counting those against the announced total is a fair approximation - and far
# better than staring at a log wondering whether it has hung.
#
# The phases, in the order they appear:
#
#   fetch      "Get:N ..."            downloading, ends with "Fetched X in Y"
#   unpack     "Unpacking pkg ..."    one line per package
#   configure  "Setting up pkg ..."   one line per package, the slowest phase
#
# Progress is reported over unpack+configure, which is where nearly all the
# wall-clock time goes on this board.
set -eu

LOG=${LOG:-/home/arduino/os-update.log}
MODE=adb
WATCH=0
for a in "$@"; do
    case "$a" in
        --watch) WATCH=1 ;;
        --ssh)   MODE=ssh ;;
        --log=*) LOG=${a#--log=} ;;
        -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
    esac
done

HERE=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)

remote() {
    if [ "$MODE" = ssh ]; then
        sh "$HERE/bench/remote.sh" "$1"
    else
        adb shell "$1" 2>/dev/null | tr -d '\r'
    fi
}

report() {
    # One round trip: everything we need, computed on the board.
    out=$(remote "
        L=$LOG
        [ -r \$L ] || { echo 'MISSING'; exit 0; }
        # 'N upgraded, M newly installed, K to remove'
        totals=\$(grep -oE '[0-9]+ upgraded, [0-9]+ newly installed' \$L | tail -1)
        up=\$(echo \"\$totals\" | grep -oE '^[0-9]+' || echo 0)
        new=\$(echo \"\$totals\" | grep -oE '[0-9]+ newly' | grep -oE '^[0-9]+' || echo 0)
        unp=\$(grep -c '^Unpacking ' \$L || true)
        cfg=\$(grep -c '^Setting up ' \$L || true)
        fetched=\$(grep -c '^Fetched ' \$L || true)
        last=\$(tail -1 \$L)
        echo \"\$up|\$new|\$unp|\$cfg|\$fetched|\$last\"
    ")

    case "$out" in
        *MISSING*) echo "no update log at $LOG (has the update started?)"; return ;;
    esac

    up=$(echo "$out" | cut -d'|' -f1)
    new=$(echo "$out" | cut -d'|' -f2)
    unp=$(echo "$out" | cut -d'|' -f3)
    cfg=$(echo "$out" | cut -d'|' -f4)
    fetched=$(echo "$out" | cut -d'|' -f5)
    last=$(echo "$out" | cut -d'|' -f6-)

    total=$(( ${up:-0} + ${new:-0} ))
    if [ "$total" -le 0 ]; then
        echo "phase: resolving packages (apt has not announced a total yet)"
        echo "  last: $last"
        return
    fi

    done_ops=$(( ${unp:-0} + ${cfg:-0} ))
    total_ops=$(( total * 2 ))
    pct=$(( done_ops * 100 / total_ops ))
    [ "$pct" -gt 100 ] && pct=100

    if [ "${fetched:-0}" -eq 0 ]; then
        phase="downloading"
    elif [ "${cfg:-0}" -eq 0 ]; then
        phase="unpacking"
    else
        phase="configuring"
    fi

    # A short bar, because a number alone does not show movement.
    filled=$(( pct / 5 ))
    bar=""
    i=0
    while [ "$i" -lt 20 ]; do
        if [ "$i" -lt "$filled" ]; then bar="${bar}#"; else bar="${bar}."; fi
        i=$((i + 1))
    done

    printf '[%s] %3d%%  %s  (unpacked %s/%s, configured %s/%s)\n' \
        "$bar" "$pct" "$phase" "${unp:-0}" "$total" "${cfg:-0}" "$total"
    printf '   %s\n' "$(echo "$last" | cut -c1-72)"
}

if [ "$WATCH" -eq 1 ]; then
    while true; do
        report
        sleep 15
    done
else
    report
fi

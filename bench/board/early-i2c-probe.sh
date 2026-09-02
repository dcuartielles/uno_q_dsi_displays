#!/bin/sh
# Probe the CCI I2C devices from the earliest moment userspace can, and log the
# ERROR CODES. Runs ON the board, from a systemd unit that starts before the
# network is up.
#
# Why
# ---
# The cold-boot failure has always been described as "the CCI bus is dead for
# the first 30-90 seconds", but the boot timeline does not support that:
#
#   [ 4.07s] pca953x 0-0026: bound OK          <-- same bus, working
#   [10.31s] attiny: write reg=0x83 failed -110
#   [32.13s] attiny: last failure
#   [65.27s] edt_ft5x06 0-0038: probe succeeds
#
# pca953x is on the same bus and bound cleanly before the failures started, and
# the touch controller's failure is downstream (its reset line runs through the
# attiny over I2C). So the bus may be perfectly healthy while only the panel
# controller is unresponsive.
#
# That distinction decides the fix, and the error code settles it:
#
#   ENXIO / "No such device"  the address was NAKed  -> the DEVICE is not
#                             answering; it needs time, not bus recovery
#   ETIMEDOUT / "timed out"   the transfer never completed -> the BUS is
#                             stuck; it needs I2C bus recovery
#
# SSH is not up until 30-50s, by which time the window has often closed, so
# this has to run early and log to a file.
#
# Read the result after a cold boot:
#     cat /var/log/uno-q-early-i2c.log
set -u

LOG=${LOG:-/var/log/uno-q-early-i2c.log}
UNTIL=${UNTIL:-120}      # stop probing at this uptime, in seconds
INTERVAL=${INTERVAL:-1}

# 0x26 is the carrier's GPIO expander - our CONTROL. It shares the bus with the
# panel controller but nothing else touches it, so if it answers while 0x45
# does not, the bus is fine and the attiny is the problem.
#
# 0x45 is the panel controller (REG_ID, a harmless read).
# 0x38 is the touchscreen, held in reset by the attiny - expected to fail while
# the attiny does, which is why it is not evidence on its own.
PROBES="0x26:0x00 0x45:0x80 0x38:0x00"

# Bus numbering is not stable across boots, so discover it. Very early in boot
# the i2c devices may not exist yet, so fall back to scanning the adapters.
find_bus() {
    b=$(ls -d /sys/bus/i2c/devices/*-0045 2>/dev/null | head -1 \
        | sed 's#.*/##; s/-.*//')
    [ -n "$b" ] && { echo "$b"; return; }
    for d in /sys/class/i2c-adapter/i2c-*; do
        [ -e "$d" ] || continue
        n=$(basename "$d" | sed 's/i2c-//')
        case "$(cat "$d/name" 2>/dev/null)" in *cci*|*CCI*) echo "$n"; return;; esac
    done
    echo ""
}

{
    echo "=== uno-q early I2C probe ==="
    echo "boot: $(date -Is 2>/dev/null)"
    echo "columns: uptime  addr  result"
    echo
} > "$LOG" 2>/dev/null

BUS=""
while [ "$(cut -d. -f1 /proc/uptime)" -lt "$UNTIL" ]; do
    [ -n "$BUS" ] || BUS=$(find_bus)
    T=$(cut -d. -f1 /proc/uptime)

    if [ -z "$BUS" ]; then
        echo "${T}s  (no CCI adapter yet)" >> "$LOG"
        sleep "$INTERVAL"
        continue
    fi

    line="${T}s bus=$BUS"
    for p in $PROBES; do
        addr=${p%%:*}
        reg=${p##*:}
        out=$(i2ctransfer -y -f "$BUS" "w1@$addr" "$reg" r1 2>&1)
        case "$out" in
            0x*)          res="ok=$out" ;;
            *"No such device"*) res="ENXIO(nak)" ;;
            *"emote I/O"*)      res="EREMOTEIO(nak)" ;;
            *imed*out*)         res="ETIMEDOUT(bus)" ;;
            *)                  res="err:$(echo "$out" | tr -d '\n' | cut -c1-40)" ;;
        esac
        line="$line  $addr=$res"
    done
    echo "$line" >> "$LOG"
    sleep "$INTERVAL"
done

{
    echo
    echo "=== probing finished at $(cut -d. -f1 /proc/uptime)s ==="
    echo "attiny write failures this boot: $(dmesg 2>/dev/null | grep -c 'attiny:.*failed')"
    echo "cci timeouts this boot         : $(dmesg 2>/dev/null | grep -c 'cci.*timeout')"
} >> "$LOG" 2>/dev/null

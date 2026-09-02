#!/bin/sh
# Runs ON the UNO Q. Stdin secrets contract: 1. sudo password  2. SSID  3. wifi pw
#
# LAYER 2 COMPARISON - actually diff the driver sources, rather than eyeballing
# one function and assuming the rest matches.
#
#   RPi downstream : raspberrypi/linux  rpi-6.12.y
#   what we built  : arduino/linux-qcom @122c2c22d838  (mainline, our kernel's commit)
unset HISTFILE
IFS= read -r SUDO_PASS; IFS= read -r WIFI_SSID; IFS= read -r WIFI_PASS

D="$HOME/driver-compare"
mkdir -p "$D/rpi" "$D/mainline" && cd "$D" || exit 1

RPI=https://raw.githubusercontent.com/raspberrypi/linux/rpi-6.12.y
MLN=https://raw.githubusercontent.com/arduino/linux-qcom/122c2c22d838

for f in drivers/regulator/rpi-panel-attiny-regulator.c \
         drivers/gpu/drm/bridge/tc358762.c \
         drivers/input/touchscreen/edt-ft5x06.c ; do
    n=$(basename "$f")
    [ -s "rpi/$n" ]      || curl -fsSL --max-time 60 "$RPI/$f" -o "rpi/$n" 2>/dev/null
    [ -s "mainline/$n" ] || curl -fsSL --max-time 60 "$MLN/$f" -o "mainline/$n" 2>/dev/null
    printf '%-34s rpi=%-6s mainline=%s\n' "$n" \
        "$(wc -l < "rpi/$n" 2>/dev/null || echo ERR)" \
        "$(wc -l < "mainline/$n" 2>/dev/null || echo ERR)"
done

for n in rpi-panel-attiny-regulator.c tc358762.c edt-ft5x06.c; do
    echo
    echo "################################################################"
    echo "#  $n   :  RPi downstream  vs  mainline (what we built)"
    echo "################################################################"
    if [ -s "rpi/$n" ] && [ -s "mainline/$n" ]; then
        if diff -q "rpi/$n" "mainline/$n" >/dev/null 2>&1; then
            echo "IDENTICAL"
        else
            echo "--- differences (unified, 2 lines context) ---"
            diff -u2 "rpi/$n" "mainline/$n" | head -120
            echo "--- diffstat ---"
            diff "rpi/$n" "mainline/$n" | grep -c '^[<>]'
            echo "  (lines differing)"
        fi
    else
        echo "one or both files missing - cannot diff"
    fi
done

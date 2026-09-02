#!/bin/sh
# Runs ON the UNO Q. Stdin secrets contract: 1. sudo password  2. SSID  3. wifi pw
#
# regulator-panel-avdd failed its GPIO setup at 5.0s of boot with -ETIMEDOUT,
# and that single failure blocks the whole DSI panel chain. The same writes work
# fine once the bus has settled - so retry the bind NOW, after boot.
unset HISTFILE
IFS= read -r SUDO_PASS; SUDO_PASS=$(printf '%s' "$SUDO_PASS" | tr -d '\r')
IFS= read -r WIFI_SSID
IFS= read -r WIFI_PASS
S() { printf '%s\n' "$SUDO_PASS" | sudo -S -p '' "$@"; }
S true 2>/dev/null || { echo "SUDO PASSWORD REJECTED"; exit 1; }

echo "=== panel regulator platform devices ==="
ls /sys/bus/platform/devices/ | grep -i "regulator-panel" || echo "(none)"
echo "--- currently bound to reg-fixed-voltage ---"
ls /sys/bus/platform/drivers/reg-fixed-voltage/ | grep -i regulator-panel || echo "(none bound)"

S dmesg -C

echo
echo "=== attempt to bind each panel regulator ==="
for d in $(ls /sys/bus/platform/devices/ | grep -i "regulator-panel"); do
    printf '  binding %s ... ' "$d"
    if S sh -c "echo '$d' > /sys/bus/platform/drivers/reg-fixed-voltage/bind" 2>/dev/null; then
        echo "OK"
    else
        echo "failed (may already be bound)"
    fi
    sleep 1
done

echo
echo "=== dmesg since the bind attempts ==="
S dmesg | tail -30

echo
echo "=== regulators now ==="
for r in /sys/class/regulator/*/; do
    n=$(cat "$r/name" 2>/dev/null)
    case "$n" in *panel*|*tc358762*) echo "  $n: $(cat "$r/state" 2>/dev/null)";; esac
done

echo
echo "=== did the DSI panel chain come up? ==="
ls /sys/class/drm/
for s in /sys/class/drm/*/status; do [ -f "$s" ] && echo "  $(basename "$(dirname "$s")") => $(cat "$s")"; done

echo
echo "=== backlight ==="
BL=$(ls -d /sys/class/backlight/*/ 2>/dev/null | head -1)
if [ -n "$BL" ]; then
    echo "  $BL brightness=$(cat "$BL/brightness")"
    echo
    echo "*** WATCH THE PANEL - blink x4 ***"
    sleep 2
    i=1
    while [ $i -le 4 ]; do
        S sh -c "echo 0 > $BL/brightness";   sleep 2
        S sh -c "echo 255 > $BL/brightness"; sleep 2
        i=$((i+1))
    done
fi

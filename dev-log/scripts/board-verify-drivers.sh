#!/bin/sh
# Runs ON the UNO Q. Stdin secrets contract: 1. sudo password  2. SSID  3. wifi pw
#
# Confirm the PATCHED driver builds are still installed and live after the
# overlay swapping. The .dtbo tests never touched /lib/modules, but verify
# rather than assume.
#
# Expected patches:
#   tc358762.ko                  - LCD_* DPI timing writes, init from pre_enable
#   rpi-panel-attiny-regulator.ko- write retries (75s deadline), cached is_enabled
unset HISTFILE
IFS= read -r SUDO_PASS; SUDO_PASS=$(printf '%s' "$SUDO_PASS" | tr -d '\r')
IFS= read -r WIFI_SSID
IFS= read -r WIFI_PASS
S() { printf '%s\n' "$SUDO_PASS" | sudo -S -p '' "$@"; }
S true 2>/dev/null || { echo "SUDO PASSWORD REJECTED"; exit 1; }

K=$(uname -r)

echo "=== installed module files ==="
ls -la "/lib/modules/$K/extra/" 2>/dev/null

echo
echo "=== are these the PATCHED builds? (look for our debug strings) ==="
for m in tc358762 rpi-panel-attiny-regulator; do
    f="/lib/modules/$K/extra/$m.ko"
    printf '  %-30s ' "$m"
    if [ -f "$f" ]; then
        if S strings "$f" 2>/dev/null | grep -q "dbg:"; then
            echo "PATCHED  ($(S strings "$f" | grep -o '[a-z0-9]*-dbg:[^%]*' | head -1))"
        else
            echo "stock (no debug strings) <-- NOT our build"
        fi
    else
        echo "MISSING"
    fi
done

echo
echo "=== which file is the kernel actually using? ==="
for m in tc358762 rpi_panel_attiny_regulator; do
    printf '  %-30s ' "$m"
    modinfo "$m" 2>/dev/null | grep '^filename' || echo "not found"
done

echo
echo "=== loaded and bound right now ==="
lsmod | grep -iE 'tc358762|attiny|panel_simple|edt_ft5|waveshare'

echo
echo "=== proof the patched code RAN this boot ==="
echo "--- tc358762 timing-register patch ---"
dmesg | grep -i 'tc358762-dbg' || echo "  (none - patched tc358762 did not run)"
echo "--- attiny retry / cached is_enabled patch ---"
dmesg | grep -i 'attiny-dbg' | head -12 || echo "  (none - patched attiny did not run)"

echo
echo "=== overlay currently in the 5-inch slot ==="
D=/boot/efi/dtb/qcom
SLOT=$D/qrb2210-arduino-imola-carrier-media-panel-5in_touch_a-dsi.dtbo
ls -la "$SLOT"*
echo "--- is it our v2? ---"
if dtc -I dtb -O dts "$SLOT" 2>/dev/null | grep -q 'toshiba,tc358762'; then
    echo "  YES - contains tc358762 (our v2)"
    dtc -I dtb -O dts "$SLOT" 2>/dev/null | grep -E 'bridge_reg|hfront-porch|clock-frequency|ft5506|data-lanes' | sed 's/^/    /'
else
    echo "  NO - this is Arduino's himax/goodix overlay"
fi

echo
echo "=== source files on the board ==="
ls -la "$HOME/panel-build/"*.c "$HOME/panel-build/"*.orig 2>/dev/null

echo
echo "=== resulting display state ==="
for s in /sys/class/drm/*/status; do
    [ -f "$s" ] && echo "  $(basename "$(dirname "$s")") => $(cat "$s")"
done
for m in /sys/class/drm/*/modes; do [ -f "$m" ] && echo "  modes: $(tr '\n' ' ' < "$m")"; done
for r in /sys/class/regulator/*/; do
    n=$(cat "$r/name" 2>/dev/null)
    case "$n" in *tc358762*|*bridge*) echo "  regulator $n: $(cat "$r/state" 2>/dev/null)";; esac
done

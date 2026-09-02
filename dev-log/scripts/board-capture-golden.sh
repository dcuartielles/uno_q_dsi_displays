#!/bin/sh
# Runs ON the UNO Q. Stdin secrets contract: 1. sudo password  2. SSID  3. wifi pw
# Capture the exact working configuration so the published tutorial is accurate.
unset HISTFILE
IFS= read -r SUDO_PASS; SUDO_PASS=$(printf '%s' "$SUDO_PASS" | tr -d '\r')
IFS= read -r WIFI_SSID
IFS= read -r WIFI_PASS
S() { printf '%s\n' "$SUDO_PASS" | sudo -S -p '' "$@"; }

echo "=== system ==="
cat /proc/device-tree/model 2>/dev/null; echo
uname -r
grep PRETTY_NAME /etc/os-release
dpkg -l 2>/dev/null | grep -E 'arduino-unoq|arduino-linux-config|linux-image|linux-headers' | awk '{print "  "$2" "$3}'

echo
echo "=== display state ==="
for s in /sys/class/drm/*/status; do [ -f "$s" ] && echo "  $(basename "$(dirname "$s")") => $(cat "$s")"; done
for m in /sys/class/drm/*/modes; do [ -f "$m" ] && echo "  modes: $(tr '\n' ' ' < "$m")"; done
echo "  fb: $(cat /sys/class/graphics/fb0/virtual_size 2>/dev/null) @ $(cat /sys/class/graphics/fb0/bits_per_pixel 2>/dev/null)bpp"
echo "  backlight: $(ls /sys/class/backlight/ 2>/dev/null)"
echo "  dsi errors: $(dmesg | grep -c dsi_err)"

echo
echo "=== which drivers are actually BOUND (the minimal set) ==="
for d in /sys/bus/mipi-dsi/devices/*/driver /sys/bus/i2c/devices/*/driver; do
    [ -L "$d" ] || continue
    echo "  $(basename "$(dirname "$d")") -> $(basename "$(readlink "$d")")"
done

echo
echo "=== modules loaded, with use counts ==="
lsmod | grep -iE 'panel_simple|attiny|chipone|tc358762|edt_ft5|goodix'

echo
echo "=== our installed/modified module files ==="
K=$(uname -r)
ls -la "/lib/modules/$K/extra/" 2>/dev/null
ls -la "/lib/modules/$K/kernel/drivers/gpu/drm/panel/panel-simple.ko"* 2>/dev/null

echo
echo "=== autoload config ==="
cat /etc/modules-load.d/panel-tc358762.conf 2>/dev/null

echo
echo "=== carrier config ==="
arduino-linux-config carrier show 2>&1 | head -6

echo
echo "=== the live overlay in the 5-inch slot ==="
D=/boot/efi/dtb/qcom
SLOT=$D/qrb2210-arduino-imola-carrier-media-panel-5in_touch_a-dsi.dtbo
md5sum "$SLOT" "$HOME/panel-build/uno-q-waveshare-5in-800x480-v4-direct.dtbo" 2>/dev/null
dtc -I dtb -O dts "$SLOT" 2>/dev/null | grep -E 'compatible|data-lanes|regulator-name' | sed 's/^/  /'

echo
echo "=== is the patched attiny driver actually required? ==="
echo "  reg_display consumers:"
for r in /sys/class/regulator/*/; do
    n=$(cat "$r/name" 2>/dev/null)
    case "$n" in *tc358762*|*bridge*) echo "    $n: $(cat "$r/state" 2>/dev/null) users=$(cat "$r/num_users" 2>/dev/null)";; esac
done
echo "  attiny write retries used this boot:"
dmesg | grep -o 'attempts=[0-9]*' | sort | uniq -c | sed 's/^/    /'

echo
echo "=== touch ==="
grep -iE 'Name=' /proc/bus/input/devices 2>/dev/null | sed 's/^/  /'
dmesg | grep -iE 'edt_ft5|ft5506' | tail -4

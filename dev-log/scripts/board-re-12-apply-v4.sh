#!/bin/sh
# Runs ON the UNO Q. Stdin secrets contract: 1. sudo password  2. SSID  3. wifi pw
# Compile and apply v4 (direct DSI panel, no bridge), then reboot.
unset HISTFILE
IFS= read -r SUDO_PASS; SUDO_PASS=$(printf '%s' "$SUDO_PASS" | tr -d '\r')
IFS= read -r WIFI_SSID
IFS= read -r WIFI_PASS
S() { printf '%s\n' "$SUDO_PASS" | sudo -S -p '' "$@"; }
S true 2>/dev/null || { echo "SUDO PASSWORD REJECTED"; exit 1; }

D=/boot/efi/dtb/qcom
SRC=$HOME/panel-build/uno-q-waveshare-5in-800x480-v4-direct.dts
OUT=$HOME/panel-build/uno-q-waveshare-5in-800x480-v4-direct.dtbo
SLOT=$D/qrb2210-arduino-imola-carrier-media-panel-5in_touch_a-dsi.dtbo

echo "=== no bridge module needed now - drop them from autoload ==="
printf 'rpi-panel-attiny-regulator\n' > /tmp/pm.conf
S cp /tmp/pm.conf /etc/modules-load.d/panel-tc358762.conf
cat /etc/modules-load.d/panel-tc358762.conf

echo
echo "=== also shorten the attiny retry deadline (75s made bad boots crawl) ==="
sed -i 's/msecs_to_jiffies(75000)/msecs_to_jiffies(8000)/' "$HOME/panel-build/rpi-panel-attiny-regulator.c"
grep -n 'msecs_to_jiffies' "$HOME/panel-build/rpi-panel-attiny-regulator.c"
make -C "/lib/modules/$(uname -r)/build" M="$HOME/panel-build" modules 2>&1 | tail -4
S cp "$HOME/panel-build/rpi-panel-attiny-regulator.ko" "/lib/modules/$(uname -r)/extra/"
S depmod -a

echo
echo "=== compile v4 ==="
dtc -@ -I dts -O dtb -o "$OUT" "$SRC" 2>&1
[ -s "$OUT" ] || { echo ">>> COMPILE FAILED"; exit 1; }
ls -la "$OUT"

echo
echo "=== dry-run compose ==="
rm -f /tmp/v4.dtb
fdtoverlay -i "$D/qrb2210-arduino-imola-base.dtb" -o /tmp/v4.dtb \
    "$D/qrb2210-arduino-imola-carrier-media.dtbo" "$OUT" 2>&1 \
    && echo "fdtoverlay OK" || { echo ">>> compose FAILED"; exit 1; }

echo
echo "=== verify: panel present, NO bridge node ==="
dtc -I dtb -O dts /tmp/v4.dtb 2>/dev/null > /tmp/v4.dts
echo "--- panel ---"
grep -n -B2 -A5 'waveshare,4-3-inch-dsi' /tmp/v4.dts | head -14
echo "--- bridges (should be none of ours) ---"
grep -cE 'toshiba,tc358762|chipone,icn6211' /tmp/v4.dts
echo "--- data-lanes ---"
grep -n 'data-lanes' /tmp/v4.dts

echo
echo "=== install (v3 kept as .v3) ==="
[ -f "$SLOT.v3" ] || S cp "$SLOT" "$SLOT.v3"
S cp "$OUT" "$SLOT"
S arduino-linux-config carrier enable media-carrier display=5-dsi-touch-a 2>&1 | tail -2

echo
echo "=== rebooting in 3s ==="
S nohup sh -c 'sleep 3; systemctl reboot' >/dev/null 2>&1 &
sleep 1
echo "reboot scheduled"

#!/bin/sh
# Runs ON the UNO Q. Stdin secrets contract: 1. sudo password  2. SSID  3. wifi pw
#
# Stage 6: compile our custom panel overlay and DRY-RUN the composition.
# Installs the .dtbo but does NOT enable it or reboot - that is stage 7.
#
# Because arduino-linux-config hardcodes its option names and .dtbo filenames
# in the Go binary, we cannot register a new display option. Instead we take
# over the 5-inch slot: back up Arduino's 5in_touch_a overlay and put ours in
# its place, then use the official CLI with display=5-dsi-touch-a.
unset HISTFILE

IFS= read -r SUDO_PASS; SUDO_PASS=$(printf '%s' "$SUDO_PASS" | tr -d '\r')
IFS= read -r WIFI_SSID
IFS= read -r WIFI_PASS

S() { printf '%s\n' "$SUDO_PASS" | sudo -S -p '' "$@"; }
S true 2>/dev/null || { echo "SUDO PASSWORD REJECTED"; exit 1; }

D=/boot/efi/dtb/qcom
SRC=$HOME/panel-build/uno-q-waveshare-5in-800x480-tc358762.dts
OUT=$HOME/panel-build/uno-q-waveshare-5in-800x480-tc358762.dtbo
SLOT=$D/qrb2210-arduino-imola-carrier-media-panel-5in_touch_a-dsi.dtbo

echo "=== 1. compile the overlay ==="
dtc -@ -I dts -O dtb -o "$OUT" "$SRC" 2>&1
if [ ! -s "$OUT" ]; then echo ">>> COMPILE FAILED"; exit 1; fi
ls -la "$OUT"

echo
echo "=== 2. sanity: fixups our overlay expects from the base DTB ==="
dtc -I dtb -O dts "$OUT" 2>/dev/null | sed -n '/__fixups__/,/};/p'

echo
echo "=== 3. DRY RUN: compose base + carrier-media + our panel ==="
rm -f /tmp/test-compose.dtb
if fdtoverlay -i "$D/qrb2210-arduino-imola-base.dtb" -o /tmp/test-compose.dtb \
      "$D/qrb2210-arduino-imola-carrier-media.dtbo" "$OUT" 2>&1; then
    echo "fdtoverlay exit: OK"
else
    echo ">>> fdtoverlay FAILED"; exit 1
fi
ls -la /tmp/test-compose.dtb

echo
echo "=== 4. verify the composed tree actually contains our nodes ==="
dtc -I dtb -O dts /tmp/test-compose.dtb 2>/dev/null > /tmp/test-compose.dts
echo "--- tc358762 bridge ---"
grep -n -A6 'toshiba,tc358762' /tmp/test-compose.dts | head -20
echo "--- attiny regulator ---"
grep -n -A4 '7inch-touchscreen-panel-regulator' /tmp/test-compose.dts | head -12
echo "--- touchscreen ---"
grep -n -A4 'edt,edt-ft5406' /tmp/test-compose.dts | head -10
echo "--- panel timing ---"
grep -n -A6 'panel-dpi' /tmp/test-compose.dts | head -16
echo "--- DSI data-lanes (expect 0x00 0x01 only) ---"
grep -n 'data-lanes' /tmp/test-compose.dts

echo
echo "=== 5. confirm the ANX7625 is NOT also claiming the DSI output ==="
grep -c 'anx7625' /tmp/test-compose.dts || true

echo
echo "=== 6. install: back up Arduino's overlay, put ours in the 5in slot ==="
if [ ! -f "$SLOT.orig" ]; then
    S cp "$SLOT" "$SLOT.orig"
    echo "backed up original -> $SLOT.orig"
else
    echo "backup already exists at $SLOT.orig (leaving it)"
fi
S cp "$OUT" "$SLOT"
ls -la "$SLOT" "$SLOT.orig"

echo
echo "=== stage 6 done - overlay installed, NOT yet enabled ==="
echo "next: arduino-linux-config carrier enable media-carrier display=5-dsi-touch-a"

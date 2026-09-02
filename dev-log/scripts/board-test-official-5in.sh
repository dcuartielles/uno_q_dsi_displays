#!/bin/sh
# Runs ON the UNO Q. Stdin secrets contract: 1. sudo password  2. SSID  3. wifi pw
#
# Re-run Arduino's OFFICIAL 5-dsi-touch-a configuration against our 800x480
# panel, now that the board is on good power and the driver patches are in.
# The earlier attempt was on a starved supply, so its -110 timeouts were not
# trustworthy evidence. This is the clean re-test.
#
# Fully reversible: our v2 overlay is saved as .v2 and restored by
# scripts/board-restore-v2.sh
unset HISTFILE
IFS= read -r SUDO_PASS; SUDO_PASS=$(printf '%s' "$SUDO_PASS" | tr -d '\r')
IFS= read -r WIFI_SSID
IFS= read -r WIFI_PASS
S() { printf '%s\n' "$SUDO_PASS" | sudo -S -p '' "$@"; }
S true 2>/dev/null || { echo "SUDO PASSWORD REJECTED"; exit 1; }

D=/boot/efi/dtb/qcom
SLOT=$D/qrb2210-arduino-imola-carrier-media-panel-5in_touch_a-dsi.dtbo

echo "=== overlay files present ==="
ls -la "$SLOT"*

echo
echo "=== save our v2 overlay, restore Arduino's original ==="
S cp "$SLOT" "$SLOT.v2"
[ -f "$SLOT.orig" ] || { echo "ERROR: no .orig backup"; exit 1; }
S cp "$SLOT.orig" "$SLOT"
echo "  slot now holds Arduino's original 5in_touch_a overlay"
cmp -s "$SLOT" "$SLOT.orig" && echo "  verified identical to .orig"

echo
echo "=== what the official overlay targets ==="
dtc -I dtb -O dts "$SLOT" 2>/dev/null | grep -E 'compatible = "(waveshare|himax|goodix)|data-lanes' | sed 's/^/  /'

echo
echo "=== apply it ==="
S arduino-linux-config carrier enable media-carrier display=5-dsi-touch-a 2>&1
arduino-linux-config carrier show 2>&1 | head -6

echo
echo "=== rebooting in 3s ==="
S nohup sh -c 'sleep 3; systemctl reboot' >/dev/null 2>&1 &
sleep 1
echo "reboot scheduled"

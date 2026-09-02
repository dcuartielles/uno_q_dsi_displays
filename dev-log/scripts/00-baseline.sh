#!/bin/sh
# Run this ON the Arduino UNO Q (over SSH), with the Media Carrier attached and the
# Waveshare panel plugged into the 22-pin DSI connector.
#
#   scp scripts/00-baseline.sh <user>@<unoq>:~/ && ssh <user>@<unoq> 'sh 00-baseline.sh' > baseline.txt
#
# It only reads. Nothing here modifies the boot configuration.

sep() { printf '\n===== %s =====\n' "$1"; }

sep "system"
uname -a
cat /etc/os-release 2>/dev/null
cat /proc/device-tree/model 2>/dev/null; echo

sep "VERSIONS / update status"
# Current images are Debian 13 "Trixie" with kernel 6.16.x.
# Debian 12 "Bookworm" or an older kernel => image predates Media Carrier support.
printf 'kernel:  %s\n' "$(uname -r)"
grep -E 'PRETTY_NAME|VERSION_CODENAME' /etc/os-release 2>/dev/null
echo "--- arduino stack ---"
dpkg -l 2>/dev/null | grep -i arduino
arduino-app-cli version 2>/dev/null || arduino-app-cli --version 2>/dev/null
echo "--- pending updates ---"
apt list --upgradable 2>/dev/null | head -50

sep "DECISIVE CHECK: does this image know about the Media Carrier?"
# Empty result here means the image is too old and must be reflashed before
# any device tree work - there is no template overlay to start from.
ls /boot/efi/dtb/qcom/ 2>/dev/null | grep -i carrier-media || \
    echo ">>> NO carrier-media overlays found - image predates Media Carrier support"
echo "--- any panel overlay at all? (a 5in one would be a jackpot) ---"
ls /boot/efi/dtb/qcom/ 2>/dev/null | grep -iE 'panel|dsi'

sep "boot: device trees available"
ls -la /boot/efi/dtb/qcom/ 2>/dev/null

sep "boot: loader entries (the currently selected DTB)"
ls -la /boot/efi/loader/entries/ 2>/dev/null
cat /boot/efi/loader/entries/*.conf 2>/dev/null
bootctl status 2>/dev/null | head -40

sep "drm / display devices"
ls -la /sys/class/drm/ 2>/dev/null
ls -la /dev/dri/ /dev/fb* 2>/dev/null
for s in /sys/class/drm/*/status; do
    [ -f "$s" ] && printf '%s: %s\n' "$s" "$(cat "$s")"
done

sep "dmesg: display pipeline"
dmesg 2>/dev/null | grep -iE 'msm|mdss|dsi|drm|anx7625|panel|backlight|bridge'

sep "panel + bridge drivers present in this kernel"
ls /lib/modules/"$(uname -r)"/kernel/drivers/gpu/drm/panel/ 2>/dev/null
echo "--- bridge ---"
ls /lib/modules/"$(uname -r)"/kernel/drivers/gpu/drm/bridge/ 2>/dev/null
echo "--- waveshare / tc358762 anywhere ---"
find /lib/modules/"$(uname -r)" -iname '*waveshare*' -o -iname '*tc358762*' 2>/dev/null

sep "kernel build support (can we compile modules on-device?)"
ls -d /usr/src/* 2>/dev/null
ls -l /lib/modules/"$(uname -r)"/build 2>/dev/null
dpkg -l 2>/dev/null | grep -iE 'linux-(image|headers|source)|device-tree|dtc'
command -v dtc fdtoverlay modetest kmscube evtest i2cdetect 2>/dev/null

sep "i2c buses (looking for the panel's controller / touch)"
ls /dev/i2c-* 2>/dev/null
for b in /dev/i2c-*; do
    n=${b#/dev/i2c-}
    printf '\n--- i2c bus %s ---\n' "$n"
    i2cdetect -y "$n" 2>/dev/null
done

sep "input devices (touch)"
cat /proc/bus/input/devices 2>/dev/null

sep "backlight"
ls -la /sys/class/backlight/ 2>/dev/null

sep "done"

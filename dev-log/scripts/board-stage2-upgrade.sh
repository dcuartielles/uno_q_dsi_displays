#!/bin/sh
# Runs ON the UNO Q. Stdin secrets contract (same runner as the other stages):
#   1. sudo password   2. wifi SSID   3. wifi password
#
# Stage 2: the real upgrade.
#   a) full-upgrade the ~232 stale packages
#   b) install the arduino-unoq meta-package, which is the important part:
#        Depends: linux-image-7.0.0-g122c2c22d838   <- carries the new DTBs/DTBOs
#        Depends: arduino-linux-config              <- official DT-overlay CLI
#        Depends: arduino-unoq-config, arduino-cloud-connector, ...
#
# Does NOT reboot. We reboot deliberately afterwards.
# NB: no `set +o history` - dash exits silently on an unknown set -o option.
unset HISTFILE

IFS= read -r SUDO_PASS; SUDO_PASS=$(printf '%s' "$SUDO_PASS" | tr -d '\r')
IFS= read -r WIFI_SSID
IFS= read -r WIFI_PASS

S() { printf '%s\n' "$SUDO_PASS" | sudo -S -p '' "$@"; }

S true 2>/dev/null || { echo "SUDO PASSWORD REJECTED - stopping"; exit 1; }
getent hosts apt-repo.arduino.cc >/dev/null 2>&1 || { echo "no internet - stopping"; exit 1; }

APT="env DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a"
OPTS="-o Dpkg::Options::=--force-confold -o Dpkg::Options::=--force-confdef"

echo "=== BEFORE ==="
date
uname -r
df -h / /boot/efi 2>/dev/null | tail -3
dpkg -l | grep -iE 'arduino-app|arduino-cli|arduino-router|linux-image'

echo
echo "=== 1. apt-get update ==="
S $APT /usr/bin/apt-get update 2>&1 | tail -8

echo
echo "=== 2. full-upgrade (this is the long one) ==="
S $APT apt-get -y $OPTS full-upgrade 2>&1 | tail -40

echo
echo "=== 3. install arduino-unoq meta-package (new kernel + overlay tooling) ==="
S $APT apt-get -y $OPTS install arduino-unoq 2>&1 | tail -50

echo
echo "=== 4. autoremove / configure leftovers ==="
S /usr/bin/dpkg --configure -a 2>&1 | tail -5
S $APT apt-get -y autoremove 2>&1 | tail -8

echo
echo "=== AFTER ==="
echo "--- running kernel (still old until reboot) ---"
uname -r
echo "--- installed kernels ---"
dpkg -l | grep -i linux-image
echo "--- arduino stack ---"
dpkg -l | grep -iE 'arduino-app|arduino-cli|arduino-router|arduino-unoq|arduino-linux-config'

echo
echo "*** THE DECISIVE CHECK ***"
echo "--- carrier-media overlays ---"
ls /boot/efi/dtb/qcom/ 2>/dev/null | grep -i carrier-media || echo ">>> STILL NONE"
echo "--- panel / dsi overlays ---"
ls /boot/efi/dtb/qcom/ 2>/dev/null | grep -iE 'panel|dsi' || echo ">>> none"
echo "--- every .dtbo now present ---"
ls /boot/efi/dtb/qcom/*.dtbo 2>/dev/null || echo ">>> no .dtbo files"
echo "--- imola files ---"
ls -la /boot/efi/dtb/qcom/ 2>/dev/null | grep -i imola
echo "--- boot loader entries ---"
ls /boot/efi/loader/entries/ 2>/dev/null

echo
echo "--- the new overlay CLI, if it landed ---"
command -v arduino-linux-config && arduino-linux-config --help 2>&1 | head -30

echo
echo "=== stage 2 done - REBOOT REQUIRED ==="

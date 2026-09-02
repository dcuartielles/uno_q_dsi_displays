#!/bin/sh
# Runs ON the UNO Q. Stdin secrets contract: 1. sudo password  2. SSID  3. wifi pw
#
# Stage 3: install the arduino-unoq meta-package, which stage 2 could not.
#
# Why stage 2 failed:
#   arduino-unoq Depends: alsa-ucm-conf (>= 1.2.14-1qcom0.1arduino3)
#   An apt pin gives trixie-backports priority 900, so apt insisted on
#   alsa-ucm-conf 1.2.16.1-1~bpo13+1, which Depends libasound2t64 (>= 1.2.15)
#   while trixie only offers 1.2.14-1. Deadlock.
#   The plain Debian 1.2.14-1 that is installed is LOWER than Arduino's
#   1.2.14-1qcom0.1arduino3, so it does not satisfy the dependency either.
#
# Fix: name Arduino's vendor version explicitly. It is the correct one for this
# board anyway - it carries the Qualcomm UCM audio routing configuration.
unset HISTFILE

IFS= read -r SUDO_PASS; SUDO_PASS=$(printf '%s' "$SUDO_PASS" | tr -d '\r')
IFS= read -r WIFI_SSID
IFS= read -r WIFI_PASS

S() { printf '%s\n' "$SUDO_PASS" | sudo -S -p '' "$@"; }
S true 2>/dev/null || { echo "SUDO PASSWORD REJECTED - stopping"; exit 1; }

APT="env DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a"
OPTS="-o Dpkg::Options::=--force-confold -o Dpkg::Options::=--force-confdef"

echo "=== where does the backports priority-900 pin come from? ==="
ls -la /etc/apt/preferences.d/ 2>/dev/null
cat /etc/apt/preferences.d/* 2>/dev/null
cat /etc/apt/preferences 2>/dev/null

echo
echo "=== 1. pin alsa-ucm-conf to Arduino's vendor version ==="
S $APT apt-get -y $OPTS install alsa-ucm-conf=1.2.14-1qcom0.1arduino3 2>&1 | tail -20

echo
echo "=== 2. install arduino-unoq (pulls kernel 7.0.0 + arduino-linux-config) ==="
S $APT apt-get -y $OPTS install arduino-unoq 2>&1 | tail -60

echo
echo "=== 3. configure leftovers ==="
S /usr/bin/dpkg --configure -a 2>&1 | tail -5

echo
echo "=== AFTER ==="
echo "--- running kernel (old until reboot) ---"
uname -r
echo "--- installed kernels ---"
dpkg -l | grep -i linux-image
echo "--- arduino packages ---"
dpkg -l | grep -iE 'arduino-unoq|arduino-linux-config|arduino-app|arduino-cli|arduino-router'

echo
echo "*** THE DECISIVE CHECK ***"
echo "--- carrier-media overlays ---"
ls /boot/efi/dtb/qcom/ 2>/dev/null | grep -i carrier-media || echo ">>> STILL NONE"
echo "--- panel / dsi overlays ---"
ls /boot/efi/dtb/qcom/ 2>/dev/null | grep -iE 'panel|dsi' || echo ">>> none"
echo "--- every .dtbo present ---"
ls /boot/efi/dtb/qcom/*.dtbo 2>/dev/null || echo ">>> no .dtbo files"
echo "--- imola files ---"
ls -la /boot/efi/dtb/qcom/ 2>/dev/null | grep -i imola
echo "--- loader entries ---"
ls /boot/efi/loader/entries/ 2>/dev/null
echo "--- /boot/efi space ---"
df -h /boot/efi | tail -1

echo
echo "--- the official overlay CLI ---"
if command -v arduino-linux-config >/dev/null 2>&1; then
    arduino-linux-config --help 2>&1 | head -40
else
    echo ">>> arduino-linux-config not installed"
fi

echo
echo "=== stage 3 done ==="

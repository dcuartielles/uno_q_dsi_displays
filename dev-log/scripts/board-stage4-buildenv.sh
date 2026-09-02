#!/bin/sh
# Runs ON the UNO Q. Stdin secrets contract: 1. sudo password  2. SSID  3. wifi pw
#
# Stage 4: set up an on-device kernel module build environment for the two
# mainline drivers our panel needs but kernel 7.0 does not ship:
#   drivers/gpu/drm/bridge/tc358762.c
#   drivers/regulator/rpi-panel-attiny-regulator.c
unset HISTFILE

IFS= read -r SUDO_PASS; SUDO_PASS=$(printf '%s' "$SUDO_PASS" | tr -d '\r')
IFS= read -r WIFI_SSID
IFS= read -r WIFI_PASS

S() { printf '%s\n' "$SUDO_PASS" | sudo -S -p '' "$@"; }
S true 2>/dev/null || { echo "SUDO PASSWORD REJECTED"; exit 1; }

APT="env DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a"
OPTS="-o Dpkg::Options::=--force-confold -o Dpkg::Options::=--force-confdef"
K=$(uname -r)

echo "=== running kernel: $K ==="
echo
echo "=== is a matching kernel SOURCE package available? ==="
apt-cache search linux-source 2>/dev/null | head
apt-cache policy "linux-source-$K" 2>/dev/null
apt-cache policy linux-source 2>/dev/null | head -6

echo
echo "=== installing headers + toolchain ==="
S $APT apt-get -y $OPTS install "linux-headers-$K" build-essential bc kmod cpio flex bison libssl-dev 2>&1 | tail -25

echo
echo "=== verify build tree ==="
ls -ld "/lib/modules/$K/build" 2>&1
ls "/lib/modules/$K/build/Makefile" 2>&1
echo "--- kernel release the headers claim ---"
cat "/lib/modules/$K/build/include/config/kernel.release" 2>/dev/null

echo
echo "=== toolchain ==="
gcc --version 2>&1 | head -1
make --version 2>&1 | head -1
command -v dtc fdtoverlay

echo
echo "=== module signing enforced? (would block out-of-tree modules) ==="
grep -E 'CONFIG_MODULE_SIG_FORCE|CONFIG_MODULE_SIG=' "/lib/modules/$K/build/.config" 2>/dev/null || echo "(.config not readable)"
cat /sys/kernel/security/lockdown 2>/dev/null || echo "(no lockdown file - not enforced)"

echo
echo "=== do the two drivers have Kconfig entries we can mirror? ==="
grep -rn "TC358762" "/lib/modules/$K/build/include/config/" 2>/dev/null | head -3
grep -rn "RASPBERRYPI_TOUCHSCREEN\|RPI_PANEL" "/lib/modules/$K/build/include/config/" 2>/dev/null | head -3

echo
echo "=== stage 4 done ==="

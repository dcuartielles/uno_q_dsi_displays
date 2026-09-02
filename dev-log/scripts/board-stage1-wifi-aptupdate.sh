#!/bin/sh
# Runs ON the UNO Q. Reads three secrets from stdin, one per line:
#   1. sudo password
#   2. wifi SSID
#   3. wifi password
#
# The secrets are never written to disk, never placed on a command line for
# sudo, and never echoed. Shell history is disabled for this run.
#
# Stage 1 only: bring up Wi-Fi and refresh the apt index. No packages are
# installed here - the actual upgrade is stage 2, run separately.

# NB: do NOT use `set +o history` here - /bin/sh is dash, which treats an
# unknown `set -o` option as a special-builtin error and silently exits the
# whole script. Unsetting HISTFILE is enough; a non-interactive sh keeps no
# history anyway.
unset HISTFILE

# strip any CR that survived the Windows -> stdin path
IFS= read -r SUDO_PASS; SUDO_PASS=$(printf '%s' "$SUDO_PASS" | tr -d '\r')
IFS= read -r WIFI_SSID; WIFI_SSID=$(printf '%s' "$WIFI_SSID" | tr -d '\r')
IFS= read -r WIFI_PASS; WIFI_PASS=$(printf '%s' "$WIFI_PASS" | tr -d '\r')

# run a command under sudo, feeding the password via stdin (not argv, so it
# never appears in ps output or in the process table)
S() { printf '%s\n' "$SUDO_PASS" | sudo -S -p '' "$@"; }

echo "=== 0. verify sudo password ==="
if S true 2>/dev/null; then
    echo "sudo OK"
else
    echo "SUDO PASSWORD REJECTED - stopping. Check SUDO_PASS in the secrets file."
    exit 1
fi

echo
echo "=== 1. connecting to Wi-Fi ==="
echo "SSID: $WIFI_SSID"
if S nmcli dev wifi connect "$WIFI_SSID" password "$WIFI_PASS" 2>&1; then
    echo "nmcli returned success"
else
    echo "nmcli reported a problem (see above)"
fi

# wait for wlan0 to actually reach 'connected'
i=0
while [ "$i" -lt 30 ]; do
    state=$(nmcli -t -f DEVICE,STATE device 2>/dev/null | grep '^wlan0:' | cut -d: -f2)
    [ "$state" = "connected" ] && break
    i=$((i + 1))
    sleep 1
done

echo
echo "=== 2. network state ==="
nmcli -t -f DEVICE,TYPE,STATE,CONNECTION device 2>/dev/null | grep -E 'wlan0|eth'
echo "addresses: $(hostname -I)"
ip route 2>/dev/null | grep default

echo
echo "=== 3. DNS / internet reachability ==="
if getent hosts deb.debian.org >/dev/null 2>&1; then
    echo "DNS OK (deb.debian.org resolves)"
else
    echo "DNS FAILED - no usable internet, stopping before apt"
    exit 1
fi
if getent hosts apt-repo.arduino.cc >/dev/null 2>&1; then
    echo "DNS OK (apt-repo.arduino.cc resolves)"
else
    echo "WARNING: apt-repo.arduino.cc does not resolve"
fi

echo
echo "=== 4. apt update ==="
S apt-get update 2>&1 | tail -25

echo
echo "=== 5. what would be upgraded ==="
apt list --upgradable 2>/dev/null | head -60
echo "--- count ---"
apt list --upgradable 2>/dev/null | grep -c upgradable

echo
echo "=== 6. is a newer kernel available? (this is what carries the DTBs) ==="
apt-cache policy linux-image-arduino 2>/dev/null
apt-cache search linux-image 2>/dev/null | head -20
echo "--- currently installed ---"
dpkg -l 2>/dev/null | grep -i linux-image

echo
echo "=== stage 1 done ==="

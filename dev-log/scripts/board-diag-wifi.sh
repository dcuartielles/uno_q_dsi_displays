#!/bin/sh
# Can the 'arduino' user bring up Wi-Fi WITHOUT sudo (via polkit / netdev group)?
# If yes, we can do the whole update with no password at all, and leave the
# account password entirely to the user.
unset HISTFILE

IFS= read -r SUDO_PASS
IFS= read -r WIFI_SSID; WIFI_SSID=$(printf '%s' "$WIFI_SSID" | tr -d '\r')
IFS= read -r WIFI_PASS; WIFI_PASS=$(printf '%s' "$WIFI_PASS" | tr -d '\r')

echo "=== attempting nmcli connect as plain user (no sudo) ==="
echo "SSID: $WIFI_SSID"
nmcli dev wifi connect "$WIFI_SSID" password "$WIFI_PASS" 2>&1

i=0
while [ "$i" -lt 30 ]; do
    state=$(nmcli -t -f DEVICE,STATE device 2>/dev/null | grep '^wlan0:' | cut -d: -f2)
    [ "$state" = "connected" ] && break
    i=$((i + 1))
    sleep 1
done

echo
echo "=== result ==="
nmcli -t -f DEVICE,TYPE,STATE,CONNECTION device 2>/dev/null | grep wlan0
echo "addresses: $(hostname -I)"
ip route 2>/dev/null | grep default

echo
echo "=== DNS check ==="
getent hosts deb.debian.org >/dev/null 2>&1 && echo "deb.debian.org OK" || echo "deb.debian.org FAILED"
getent hosts apt-repo.arduino.cc >/dev/null 2>&1 && echo "apt-repo.arduino.cc OK" || echo "apt-repo.arduino.cc FAILED"

echo
echo "=== NOPASSWD apt-get update (no password anywhere) ==="
sudo -n /usr/bin/apt-get update 2>&1 | tail -12

echo
echo "=== upgradable packages ==="
apt list --upgradable 2>/dev/null | head -40
echo "--- count ---"
apt list --upgradable 2>/dev/null | grep -c upgradable

echo
echo "=== is a newer kernel (and therefore new DTBs) available? ==="
apt-cache policy $(dpkg -l | awk '/linux-image/{print $2}') 2>/dev/null
echo "--- all linux-image candidates in the repos ---"
apt-cache search linux-image 2>/dev/null | head -20
echo "=== done ==="

#!/bin/sh
# Diagnostic only. Shows WHY sudo failed, without ever printing the password.
unset HISTFILE

IFS= read -r SUDO_PASS; SUDO_PASS=$(printf '%s' "$SUDO_PASS" | tr -d '\r')
IFS= read -r WIFI_SSID
IFS= read -r WIFI_PASS

echo "password received: ${#SUDO_PASS} chars"
printf 'first char class: '
printf '%s' "$SUDO_PASS" | cut -c1 | tr 'A-Za-z0-9' 'aaaaaaaaaaaaaaaaaaaaaaaaaaAAAAAAAAAAAAAAAAAAAAAAAAAA9'
echo

echo "--- do we have a tty? ---"
tty || echo "(no tty - adb shell without -t)"

echo "--- sudo -n (is it passwordless?) ---"
sudo -n true 2>&1

echo "--- sudo -S with the supplied password, STDERR SHOWN ---"
printf '%s\n' "$SUDO_PASS" | sudo -S -p '' id 2>&1

echo "--- sudo -k -S retry ---"
printf '%s\n' "$SUDO_PASS" | sudo -k -S -p '' id 2>&1

echo "--- sudoers: does the user appear? ---"
groups
echo "--- askpass / requiretty hints ---"
grep -rhsE 'requiretty|askpass|targetpw|NOPASSWD' /etc/sudoers /etc/sudoers.d/ 2>/dev/null || echo "(none found / unreadable)"
echo "--- done ---"

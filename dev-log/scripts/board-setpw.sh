#!/bin/sh
# Completes what the App Lab first-setup wizard would have done: sets the
# 'arduino' Linux account password.
#
# The account currently has NO usable password - `chage -l` reports
# "password must be changed", which is why sudo refused every attempt.
# /usr/local/bin/arduino-passwd is Arduino's own root helper for exactly this,
# whitelisted NOPASSWD in sudoers, and reads the new password from stdin.
#
# The password is taken from SUDO_PASS in the local secrets file and is never
# echoed, never placed on a command line, and never written to disk.
unset HISTFILE

IFS= read -r SUDO_PASS; SUDO_PASS=$(printf '%s' "$SUDO_PASS" | tr -d '\r')
IFS= read -r WIFI_SSID
IFS= read -r WIFI_PASS

[ -n "$SUDO_PASS" ] || { echo "ERROR: SUDO_PASS is empty"; exit 1; }
echo "setting account password (${#SUDO_PASS} chars)"

printf '%s\n' "$SUDO_PASS" | sudo -n /usr/local/bin/arduino-passwd
echo "arduino-passwd exit code: $?"

echo
echo "=== verify sudo now works ==="
if printf '%s\n' "$SUDO_PASS" | sudo -S -p '' true 2>/dev/null; then
    echo "SUCCESS: sudo now accepts the password"
else
    echo "FAILED: sudo still refuses"
fi

echo
echo "=== account ageing state (should no longer say 'must be changed') ==="
chage -l arduino 2>/dev/null | head -3

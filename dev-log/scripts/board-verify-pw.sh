#!/bin/sh
# Confirms whether the password CURRENTLY in the local secrets file is the one
# the board actually accepts. Prints only pass/fail - never the value.
unset HISTFILE

IFS= read -r SUDO_PASS; SUDO_PASS=$(printf '%s' "$SUDO_PASS" | tr -d '\r')
IFS= read -r WIFI_SSID
IFS= read -r WIFI_PASS

echo "testing the ${#SUDO_PASS}-char password currently in the secrets file"
if printf '%s\n' "$SUDO_PASS" | sudo -S -k -p '' true 2>/dev/null; then
    echo "RESULT: MATCH - the board accepts the password now in the file"
else
    echo "RESULT: NO MATCH - the board's password differs from the file"
fi
echo
echo "when /etc/shadow was last written (i.e. when the password was set):"
stat -c '%y' /etc/shadow 2>/dev/null

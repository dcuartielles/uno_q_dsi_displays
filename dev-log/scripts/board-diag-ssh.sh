#!/bin/sh
# Runs ON the UNO Q. Stdin secrets contract: 1. sudo password  2. SSID  3. wifi pw
# Why is public-key auth being refused?
unset HISTFILE
IFS= read -r SUDO_PASS; SUDO_PASS=$(printf '%s' "$SUDO_PASS" | tr -d '\r')
IFS= read -r WIFI_SSID
IFS= read -r WIFI_PASS
S() { printf '%s\n' "$SUDO_PASS" | sudo -S -p '' "$@"; }
S true 2>/dev/null || { echo "SUDO PASSWORD REJECTED"; exit 1; }

echo "=== effective sshd config (relevant keys) ==="
S sshd -T 2>&1 | grep -iE "pubkeyauthentication|authorizedkeysfile|passwordauthentication|strictmodes|allowusers|denyusers|allowgroups|permitrootlogin|usepam|authenticationmethods"

echo
echo "=== config files ==="
ls -la /etc/ssh/sshd_config.d/ 2>/dev/null
echo "--- drop-ins ---"
S sh -c 'cat /etc/ssh/sshd_config.d/*.conf 2>/dev/null'
echo "--- main config, non-comment lines ---"
S grep -vE '^\s*#|^\s*$' /etc/ssh/sshd_config

echo
echo "=== recent auth attempts ==="
S journalctl -u ssh -n 30 --no-pager 2>&1 | tail -30

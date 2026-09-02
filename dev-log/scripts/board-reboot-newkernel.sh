#!/bin/sh
# Runs ON the UNO Q. Stdin secrets contract: 1. sudo password  2. SSID  3. wifi pw
#
# Boots kernel 7.0.0 for the first time, with a rollback net:
#   default  -> 6.16.7 (the known-good kernel we have been running)
#   oneshot  -> 7.0.0  (tried once)
# If 7.0.0 fails to boot, a power cycle returns to 6.16.7 automatically,
# which matters because there is no display to pick an entry from.
unset HISTFILE

IFS= read -r SUDO_PASS; SUDO_PASS=$(printf '%s' "$SUDO_PASS" | tr -d '\r')
IFS= read -r WIFI_SSID
IFS= read -r WIFI_PASS

S() { printf '%s\n' "$SUDO_PASS" | sudo -S -p '' "$@"; }
S true 2>/dev/null || { echo "SUDO PASSWORD REJECTED - stopping"; exit 1; }

OLD=3e660e15577e4d88ad85a3673a183368-6.16.7-g0dd6551ae96b.conf
NEW=3e660e15577e4d88ad85a3673a183368-7.0.0-g122c2c22d838.conf

echo "=== setting default to the KNOWN-GOOD kernel ($OLD) ==="
S bootctl set-default "$OLD" 2>&1; echo "rc=$?"

echo
echo "=== setting ONE-SHOT boot to the new kernel ($NEW) ==="
S bootctl set-oneshot "$NEW" 2>&1; echo "rc=$?"

echo
echo "=== resulting boot state ==="
S bootctl status 2>&1 | grep -iE 'default|oneshot|selected|entry' | head -10

echo
echo "NOTE: if set-default/set-oneshot reported an error, this platform may not"
echo "persist EFI variables. In that case the firmware picks the newest entry"
echo "(7.0.0) anyway, and rollback would need the loader entry to be renamed."

echo
echo "=== rebooting in 3s (adb will drop and come back) ==="
S nohup sh -c 'sleep 3; systemctl reboot' >/dev/null 2>&1 &
sleep 1
echo "reboot scheduled"

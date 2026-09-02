#!/bin/sh
# Install the early I2C probe as a systemd unit. Runs ON the board.
#
#   sudo ./install-early-probe.sh          # install and enable
#   sudo ./install-early-probe.sh remove   # remove
#
# The unit starts as early as userspace allows - before the network, before the
# display manager - because the failure window it has to observe opens at about
# 8 seconds and often closes before SSH is available.
#
# This is a diagnostic, not part of the install. It writes one line per second
# to /var/log/uno-q-early-i2c.log for the first two minutes of every boot.
set -eu

HELPER=/usr/local/libexec/uno-q-early-i2c-probe
UNIT=/etc/systemd/system/uno-q-early-i2c-probe.service
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)

if [ "${1:-}" = "remove" ]; then
    systemctl disable --now uno-q-early-i2c-probe.service 2>/dev/null || true
    rm -f "$UNIT" "$HELPER"
    systemctl daemon-reload
    echo "removed"
    exit 0
fi

[ "$(id -u)" -eq 0 ] || { echo "run with sudo" >&2; exit 1; }
command -v i2ctransfer >/dev/null 2>&1 || {
    echo "installing i2c-tools..."
    DEBIAN_FRONTEND=noninteractive apt-get -y install i2c-tools >/dev/null
}

mkdir -p "$(dirname "$HELPER")"
cp "$HERE/early-i2c-probe.sh" "$HELPER"
chmod 0755 "$HELPER"

cat > "$UNIT" <<EOF
[Unit]
Description=Probe the CCI I2C bus during early boot (uno-q-dsi-panel diagnostic)
DefaultDependencies=no
# sysinit.target completes late - ordering after it started the probe at 39s
# and missed the whole window, which opens at about 8s. Order against the
# filesystem instead, which is all this needs.
After=systemd-remount-fs.service
Before=sysinit.target

[Service]
Type=simple
ExecStart=$HELPER
# Diagnostic only: never let it hold up or fail a boot.
TimeoutStartSec=0
Restart=no

[Install]
WantedBy=sysinit.target
EOF

systemctl daemon-reload
systemctl enable uno-q-early-i2c-probe.service >/dev/null 2>&1
echo "installed and enabled"
echo
echo "Now COLD-boot the board (pull the power - a warm reboot will not"
echo "reproduce the failure), then read:"
echo
echo "    cat /var/log/uno-q-early-i2c.log"
echo
echo "What to look for, during the window where the attiny writes fail:"
echo "  0x26=ok while 0x45=ENXIO   the bus is fine, the controller is not"
echo "                             ready  -> fix by waiting in the driver"
echo "  both ETIMEDOUT             the bus is stuck"
echo "                             -> fix with I2C bus recovery"

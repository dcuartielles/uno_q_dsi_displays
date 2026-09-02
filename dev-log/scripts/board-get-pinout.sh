#!/bin/sh
# Runs ON the UNO Q. Stdin secrets contract: 1. sudo password  2. SSID  3. wifi pw
# Pull the UNO Media Carrier datasheet and extract the MIPI-DSI connector pinout,
# to find out what power rail (if any) the carrier presents to the display.
unset HISTFILE

IFS= read -r SUDO_PASS; SUDO_PASS=$(printf '%s' "$SUDO_PASS" | tr -d '\r')
IFS= read -r WIFI_SSID
IFS= read -r WIFI_PASS

S() { printf '%s\n' "$SUDO_PASS" | sudo -S -p '' "$@"; }
S true 2>/dev/null || { echo "SUDO PASSWORD REJECTED"; exit 1; }

command -v pdftotext >/dev/null 2>&1 || {
    echo "installing poppler-utils ..."
    S env DEBIAN_FRONTEND=noninteractive apt-get -y install poppler-utils 2>&1 | tail -3
}

cd /tmp || exit 1
echo "=== downloading datasheet ==="
curl -fsSL -o carrier.pdf "https://botland.com.pl/img/cms/products_28653/ASX00083-datasheet.pdf" \
    && ls -la carrier.pdf || { echo "download failed"; exit 1; }

echo
echo "=== extracting text ==="
pdftotext -layout carrier.pdf carrier.txt && wc -l carrier.txt

echo
echo "=== DSI / display connector sections ==="
grep -n -i -B4 -A30 "MIPI-DSI\|MIPI DSI\|DSI connector\|J.*DSI" carrier.txt | head -120

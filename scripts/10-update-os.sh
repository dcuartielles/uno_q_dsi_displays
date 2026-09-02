#!/bin/sh
# Bring a vanilla / launch-era UNO Q up to the kernel that has Media Carrier
# support. Safe to re-run; exits early if the board is already up to date.
#
#   sudo ./scripts/10-update-os.sh
set -e
HERE=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
. "$HERE/lib/common.sh"
need_root "$@"

step "Checking what this board has"
say "  kernel : $(uname -r)"
say "  OS     : $(. /etc/os-release; echo "$PRETTY_NAME")"

if kernel_has_carrier_overlays; then
    ok "Media Carrier overlays are present - no OS update needed"
    exit 0
fi

warn "No Media Carrier overlays in $DTB_DIR."
say  "This board is running an image from before Media Carrier support existed."
say  "The UNO Q shipped in October 2025; the carrier arrived in March 2026."
say  ""
say  "This step will update Debian and install the arduino-unoq meta-package,"
say  "which pulls in the newer kernel and the arduino-linux-config tool."

# ---------------------------------------------------------------- network ---
step "Checking the network"
if ! getent hosts deb.debian.org >/dev/null 2>&1; then
    die "No DNS. Connect Wi-Fi first, e.g.
       nmcli dev wifi list
       sudo nmcli dev wifi connect \"<SSID>\" password \"<PASSWORD>\""
fi
ok "DNS resolves"

# ------------------------------------------------------------------ clock ---
# The UNO Q has no RTC battery. Before NTP syncs, every repository fails
# signature verification with "Not live until <date>" and apt-repo.arduino.cc
# fails TLS. It looks like a broken mirror; it is just the date.
step "Waiting for the clock to sync (no RTC battery on this board)"
i=0
while [ "$i" -lt 30 ]; do
    if timedatectl show 2>/dev/null | grep -q 'NTPSynchronized=yes'; then break; fi
    i=$((i + 1)); sleep 2
done
if timedatectl show 2>/dev/null | grep -q 'NTPSynchronized=yes'; then
    ok "clock synced: $(date)"
else
    warn "clock may not be synced: $(date)"
    warn "if apt reports 'Not live until ...' signature errors, wait and re-run"
fi

# -------------------------------------------------------------------- apt ---
step "Updating Debian (this takes a while)"
apt-get update
DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a \
    apt-get -y -o Dpkg::Options::=--force-confold \
               -o Dpkg::Options::=--force-confdef full-upgrade

step "Installing the arduino-unoq meta-package (new kernel + carrier tooling)"
# A blanket full-upgrade moves Arduino's vendor-pinned packages onto generic
# Debian ones. alsa-ucm-conf is the one that then blocks arduino-unoq:
#   arduino-unoq Depends alsa-ucm-conf (>= 1.2.14-1qcom0.1arduino3)
#   but an apt pin prefers the backports build, which needs a libasound2t64
#   that is not installable. Name Arduino's build explicitly to break the tie.
if ! DEBIAN_FRONTEND=noninteractive apt-get -y install arduino-unoq 2>/dev/null; then
    warn "arduino-unoq blocked - pinning Arduino's alsa-ucm-conf and retrying"
    VER=$(apt-cache madison alsa-ucm-conf 2>/dev/null \
          | awk '/arduino/ {print $3; exit}')
    [ -n "$VER" ] || die "could not find Arduino's alsa-ucm-conf build"
    DEBIAN_FRONTEND=noninteractive apt-get -y install "alsa-ucm-conf=$VER"
    DEBIAN_FRONTEND=noninteractive apt-get -y install arduino-unoq
fi

step "Result"
if kernel_has_carrier_overlays; then
    ok "Media Carrier overlays installed in $DTB_DIR"
else
    warn "overlays still missing - check that arduino-unoq installed cleanly"
fi
say ""
say "A new kernel was installed. ${C_BLD}Reboot now${C_OFF}, then run:"
say "    sudo ./install.sh panels/<your-panel>.panel"
say ""
say "    sudo reboot"

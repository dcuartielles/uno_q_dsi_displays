#!/bin/sh
# Prepare one UNO Q over USB: update the OS, build and register the drivers.
# Runs on the HOST. One command per board.
#
#   tools/prepare-board.sh
#   tools/prepare-board.sh --serial 247242846 --panel panels/waveshare-800x480.panel
#
# What it is for
# --------------
# Bringing a batch of boards up to date, with no Media Carrier or panel
# attached and often no usable Wi-Fi. It needs nothing but a USB cable.
#
# It is idempotent: run it again on a half-finished board and it skips whatever
# is already done.
#
# The four things that make this awkward by hand, all handled here:
#
#   1. A FRESH BOARD HAS NO PASSWORD. passwd reports "NP" and the account is
#      flagged expired, so sudo fails with "unable to change expired password"
#      rather than anything that hints at the real problem. One has to be set
#      before anything else can happen.
#
#   2. THE CLOCK IS WRONG. There is no RTC battery, so a board off the shelf
#      can be months behind. Every apt repository then fails signature
#      verification with "Not live until <date>", which reads like a broken
#      mirror. The host's clock is copied over instead - and again after the
#      reboot, because it resets.
#
#   3. THERE MAY BE NO USABLE NETWORK. Guest Wi-Fi behind a captive portal is
#      no use to a headless board. Instead the host's own connection is lent to
#      it: a small proxy on the host, exposed on the board as 127.0.0.1:3128 by
#      `adb reverse`. No Wi-Fi, no portal, no credentials on the board.
#
#   4. THE TUNNEL DOES NOT SURVIVE A REBOOT. adb reverse is per-connection, so
#      it has to be re-established afterwards - easy to forget, and the failure
#      looks like a network problem rather than a missing tunnel.
#
# The display
# -----------
# The overlay IS installed and the carrier display IS enabled, so the board is
# finished: plug a Media Carrier and panel in later and it just works, with no
# second pass. That is the whole point of preparing a board.
#
# The cost is that enabling the DSI panel takes the SoC's single DSI controller
# away from the USB-C DisplayPort bridge. If you need DisplayPort on a board
# instead, pass --no-display.
#
# Workshop mode
# -------------
# --autologin makes the board boot straight to the desktop with no login
# prompt, which saves the first ten minutes of a workshop. Add
# --autologin-console to do the same on tty1. This removes a login prompt, so
# use it for workshop and demo boards rather than anything exposed; it is
# reversible with scripts/50-autologin.sh --disable.
set -eu

HERE=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
PANEL=panels/waveshare-800x480.panel
SERIAL=""
PROXY_PORT=3128
SECRETS=${UNOQ_SECRETS:-$HOME/.unoq-secrets.txt}
SKIP_OS=0
AUTOLOGIN=0
AUTOLOGIN_CONSOLE=0
NO_DISPLAY=0

while [ $# -gt 0 ]; do
    case "$1" in
        --panel)   PANEL=$2; shift 2 ;;
        --serial)  SERIAL=$2; shift 2 ;;
        --port)    PROXY_PORT=$2; shift 2 ;;
        --skip-os) SKIP_OS=1; shift ;;
        --autologin) AUTOLOGIN=1; shift ;;
        --no-display) NO_DISPLAY=1; shift ;;
        --autologin-console) AUTOLOGIN=1; AUTOLOGIN_CONSOLE=1; shift ;;
        -h|--help) sed -n '2,55p' "$0"; exit 0 ;;
        *) echo "unknown option: $1" >&2; exit 2 ;;
    esac
done

if [ -t 1 ]; then
    B=$(printf '\033[1m'); G=$(printf '\033[32m'); Y=$(printf '\033[33m')
    R=$(printf '\033[31m'); N=$(printf '\033[0m')
else
    B=''; G=''; Y=''; R=''; N=''
fi
step() { printf '\n%s==> %s%s\n' "$B" "$*" "$N"; }
ok()   { printf '%s  ok%s  %s\n' "$G" "$N" "$*"; }
warn() { printf '%s  !!%s  %s\n' "$Y" "$N" "$*"; }
die()  { printf '%s ERROR%s %s\n' "$R" "$N" "$*" >&2; exit 1; }

ADB="adb"
[ -n "$SERIAL" ] && ADB="adb -s $SERIAL"

# adb is a Windows binary under Git Bash, which rewrites arguments that look
# like absolute POSIX paths. MSYS_NO_PATHCONV stops it mangling the ON-DEVICE
# destination; host paths must still be given in Windows form.
sh_dev() { MSYS_NO_PATHCONV=1 $ADB shell "$1" 2>&1 | tr -d '\r'; }
sudo_dev() { printf '%s\n' "$PW" | MSYS_NO_PATHCONV=1 $ADB shell "sudo -S -p '' $1" 2>&1 | tr -d '\r'; }

# ------------------------------------------------------------- preflight ---
step "Finding the board"
command -v adb >/dev/null 2>&1 || die "adb is not installed"
n=$($ADB devices | grep -c "device$" || true)
[ "$n" -ge 1 ] || die "no board found over ADB. Plug one in, or pass --serial"
[ "$n" -gt 1 ] && [ -z "$SERIAL" ] && die "$n boards attached - pass --serial to choose one"
SER=$($ADB devices | awk '/device$/{print $1; exit}')
ok "board $SER"

[ -r "$SECRETS" ] || die "no secrets file at $SECRETS (needs SUDO_PASS=...)"
PW=$(grep -m1 '^SUDO_PASS' "$SECRETS" | sed 's/^[^=]*=[[:space:]]*//')
[ -n "$PW" ] || die "SUDO_PASS is empty in $SECRETS"

MODEL=$(sh_dev 'tr -d "\0" < /proc/device-tree/model 2>/dev/null')
KERNEL=$(sh_dev 'uname -r')
printf '  model  : %s\n  kernel : %s\n' "$MODEL" "$KERNEL"

# ------------------------------------------------------- 1. the password ---
step "Account password"
# "NP" means no password has ever been set, and the account is flagged expired,
# so sudo refuses with a message about token manipulation rather than anything
# about the real cause.
state=$(sh_dev 'passwd -S $(whoami) 2>/dev/null | awk "{print \$2}"')
if [ "$state" = "P" ]; then
    ok "already set"
else
    warn "no password set on this board (state '$state') - setting it"
    # NO -t here. Forcing a PTY makes passwd wait on the terminal and never
    # read the pipe, which hangs forever; without one it reads stdin normally.
    printf '%s\n%s\n' "$PW" "$PW" | MSYS_NO_PATHCONV=1 $ADB shell 'passwd' >/dev/null 2>&1 || true
    state=$(sh_dev 'passwd -S $(whoami) 2>/dev/null | awk "{print \$2}"')
    [ "$state" = "P" ] || die "could not set the account password"
    ok "set (matches SUDO_PASS)"
fi
[ "$(sudo_dev 'whoami')" = "root" ] || die "sudo still does not work"
ok "sudo works"

# ---------------------------------------------------------- 2. the clock ---
set_clock() {
    now=$(date -u '+%Y-%m-%d %H:%M:%S')
    sudo_dev "date -u -s '$now'" >/dev/null 2>&1 || true
}
step "Clock"
before=$(sh_dev 'date -u "+%Y-%m-%d"')
set_clock
ok "was $before, now $(sh_dev 'date -u "+%Y-%m-%d %H:%M"') UTC"

# ---------------------------------------------------------- 3. the tunnel --
start_tunnel() {
    # Is the proxy already listening on the host?
    if ! python -c "
import socket,sys
s=socket.socket(); s.settimeout(1)
sys.exit(0 if s.connect_ex(('127.0.0.1',$PROXY_PORT))==0 else 1)" 2>/dev/null; then
        ( cd "$HERE" && nohup python -u tools/usb-proxy.py --port "$PROXY_PORT" \
            >/tmp/unoq-usb-proxy.log 2>&1 & ) || true
        sleep 2
    fi
    $ADB reverse "tcp:$PROXY_PORT" "tcp:$PROXY_PORT" >/dev/null 2>&1 || true
}

step "Network (host connection, lent over USB)"
start_tunnel
PROXYCONF="$HERE/.99usb-proxy"
{
    echo "Acquire::http::Proxy \"http://127.0.0.1:$PROXY_PORT\";"
    echo "Acquire::https::Proxy \"http://127.0.0.1:$PROXY_PORT\";"
} > "$PROXYCONF"
# Host path in Windows form for adb; device path protected from conversion.
WINCONF=$(cd "$(dirname "$PROXYCONF")" && pwd -W 2>/dev/null || echo "$HERE")/.99usb-proxy
MSYS_NO_PATHCONV=1 $ADB push "$WINCONF" /home/arduino/.99usb-proxy >/dev/null 2>&1 \
    || die "could not push the proxy config"
sudo_dev "install -m 0644 /home/arduino/.99usb-proxy /etc/apt/apt.conf.d/99usb-proxy" >/dev/null
rm -f "$PROXYCONF"

if sh_dev "curl -s -o /dev/null -w '%{http_code}' -x http://127.0.0.1:$PROXY_PORT http://deb.debian.org/debian/dists/trixie/Release" | grep -q 200; then
    ok "board can reach the Debian archive through the host"
else
    die "the tunnel is not working. Is the host online?"
fi

# ------------------------------------------------------------- 4. the repo --
step "Copying this repository to the board"
TAR="$HERE/.unoq-repo.tgz"
( cd "$HERE" && tar czf "$TAR" install.sh uninstall.sh update.sh VERSION \
    CHANGELOG.md README.md lib scripts tools panels docs dt 2>/dev/null )
WINTAR=$(cd "$HERE" && pwd -W 2>/dev/null || echo "$HERE")/.unoq-repo.tgz
MSYS_NO_PATHCONV=1 $ADB push "$WINTAR" /home/arduino/unoq-repo.tgz >/dev/null 2>&1 \
    || die "could not push the repository"
rm -f "$TAR"
sh_dev 'rm -rf ~/uno-q-dsi-panel && mkdir -p ~/uno-q-dsi-panel && tar xzf ~/unoq-repo.tgz -C ~/uno-q-dsi-panel && chmod +x ~/uno-q-dsi-panel/*.sh ~/uno-q-dsi-panel/scripts/*.sh ~/uno-q-dsi-panel/tools/*.sh' >/dev/null
ok "copied to ~/uno-q-dsi-panel"

# --------------------------------------------------------- 5. the OS update --
has_carrier=$(sh_dev 'ls /boot/efi/dtb/qcom/ 2>/dev/null | grep -c carrier || echo 0')
if [ "$SKIP_OS" = "1" ]; then
    warn "skipping the OS update (--skip-os)"
elif [ "${has_carrier:-0}" -gt 0 ]; then
    ok "carrier support already present ($has_carrier overlays) - skipping the OS update"
else
    step "Updating the OS (this is the long part - 20 minutes or so)"
    echo "  follow it with:  tools/update-progress.sh --watch"
    sudo_dev "sh -c 'cd /home/arduino/uno-q-dsi-panel && ./scripts/10-update-os.sh > /home/arduino/os-update.log 2>&1'" >/dev/null || true
    tail=$(sh_dev 'tail -3 /home/arduino/os-update.log')
    if sh_dev 'ls /boot/efi/dtb/qcom/ 2>/dev/null | grep -c carrier' | grep -qv '^0$'; then
        ok "carrier support installed"
    else
        printf '%s\n' "$tail"
        die "the OS update did not install carrier support - see /home/arduino/os-update.log"
    fi

    step "Rebooting into the new kernel"
    sudo_dev "systemctl reboot" >/dev/null 2>&1 || true
    sleep 20
    $ADB wait-for-device >/dev/null 2>&1 || true
    i=0
    while [ "$i" -lt 60 ]; do
        sh_dev 'test -d /sys/class/net && echo up' | grep -q up && break
        sleep 5; i=$((i + 1))
    done
    ok "back up on kernel $(sh_dev 'uname -r')"

    # Both of these are lost across the reboot and are easy to forget.
    start_tunnel
    set_clock
    ok "tunnel and clock restored"
fi

# ----------------------------------------------------------- 6. the drivers --
step "Building and installing the patched drivers"
PROXY_ENV="env http_proxy=http://127.0.0.1:$PROXY_PORT https_proxy=http://127.0.0.1:$PROXY_PORT"
# curl does not read apt's proxy settings, so the build needs its own.
sudo_dev "sh -c 'cd /home/arduino/uno-q-dsi-panel && $PROXY_ENV ./scripts/20-build-drivers.sh $PANEL > /home/arduino/drivers.log 2>&1'" >/dev/null || true
if sh_dev 'tail -3 /home/arduino/drivers.log' | grep -q 'depmod'; then
    ok "drivers built and installed"
else
    sh_dev 'tail -12 /home/arduino/drivers.log'
    die "driver build failed - see /home/arduino/drivers.log"
fi

step "Registering with DKMS (so kernel upgrades rebuild them)"
sudo_dev "sh -c 'cd /home/arduino/uno-q-dsi-panel && $PROXY_ENV ./scripts/25-install-dkms.sh $PANEL > /home/arduino/dkms.log 2>&1'" >/dev/null || true
dkms_line=$(sh_dev 'dkms status uno-q-dsi-panel 2>/dev/null | head -1')
if [ -n "$dkms_line" ]; then
    ok "$dkms_line"
else
    sh_dev 'tail -12 /home/arduino/dkms.log'
    die "DKMS registration failed - see /home/arduino/dkms.log"
fi

# --------------------------------------------------- 7. the display itself --
if [ "$NO_DISPLAY" = "1" ]; then
    warn "skipping the overlay (--no-display): DisplayPort over USB-C stays available"
else
    step "Installing the panel overlay and enabling the display"
    sudo_dev "sh -c 'cd /home/arduino/uno-q-dsi-panel && ./scripts/30-install-overlay.sh $PANEL > /home/arduino/overlay.log 2>&1'" >/dev/null || true
    if sh_dev 'tail -20 /home/arduino/overlay.log' | grep -q 'Enabling the carrier display'; then
        ok "overlay installed, display enabled"
    else
        sh_dev 'tail -10 /home/arduino/overlay.log'
        die "overlay install failed - see /home/arduino/overlay.log"
    fi

    sudo_dev "sh -c 'cd /home/arduino/uno-q-dsi-panel && ./scripts/35-install-recovery.sh $PANEL > /home/arduino/recovery.log 2>&1'" >/dev/null || true
    if sh_dev 'systemctl is-enabled uno-q-dsi-panel-recover.service 2>/dev/null' | grep -q enabled; then
        ok "boot-recovery service enabled"
    else
        warn "recovery service not enabled - see /home/arduino/recovery.log"
    fi
fi

# --------------------------------------------------------- 8. workshop mode --
if [ "$AUTOLOGIN" = "1" ]; then
    step "Enabling autologin (workshop mode)"
    extra=""
    [ "$AUTOLOGIN_CONSOLE" = "1" ] && extra="--console"
    sudo_dev "sh -c 'cd /home/arduino/uno-q-dsi-panel && ./scripts/50-autologin.sh --user arduino $extra'"         | sed 's/^/  /' | tail -8
fi

# ----------------------------------------------------------------- summary --
step "Board $SER is ready"
sh_dev 'echo "  model  : $(tr -d "\0" < /proc/device-tree/model)"; echo "  kernel : $(uname -r)"; echo "  carrier: $(ls /boot/efi/dtb/qcom/ | grep -c carrier) overlays"; echo "  tooling: $(command -v arduino-linux-config >/dev/null && echo arduino-linux-config present || echo MISSING)"'
printf '\n'
if [ "$NO_DISPLAY" = "1" ]; then
    echo "The display was NOT enabled (--no-display). To enable it later:"
    echo "    sudo ./install.sh $PANEL && sudo reboot"
else
    echo "The board is finished. Plug in a Media Carrier and panel, reboot, and"
    echo "it should come up. Verify with:"
    echo ""
    echo "    sudo ./scripts/40-verify.sh $PANEL"
fi
echo ""
echo "Reboot to apply:  sudo reboot"

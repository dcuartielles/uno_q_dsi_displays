#!/bin/sh
# Boot straight to the desktop, with no login screen. Runs ON the board.
#
#   sudo ./scripts/50-autologin.sh              # enable for the current user
#   sudo ./scripts/50-autologin.sh --user pi    # enable for someone else
#   sudo ./scripts/50-autologin.sh --console    # also autologin on tty1
#   sudo ./scripts/50-autologin.sh --disable    # put it back
#   sudo ./scripts/50-autologin.sh --status
#
# For workshops: a room full of boards that each stop at a login prompt wastes
# the first ten minutes of a session, and the password is usually written on a
# whiteboard anyway.
#
# THIS REMOVES A LOGIN PROMPT. Anyone who can see the screen gets the desktop,
# and on a machine with SSH enabled that is a real exposure. Use it for
# workshop and demo boards, not for anything on a network you care about.
# --disable puts it back exactly as it was.
set -e
HERE=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
. "$HERE/lib/common.sh"

USER_NAME=""
CONSOLE=0
ACTION=enable
while [ $# -gt 0 ]; do
    case "$1" in
        --user)    USER_NAME=$2; shift 2 ;;
        --console) CONSOLE=1; shift ;;
        --disable) ACTION=disable; shift ;;
        --status)  ACTION=status; shift ;;
        -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
        *) die "unknown option: $1" ;;
    esac
done

LIGHTDM_DIR=/etc/lightdm/lightdm.conf.d
LIGHTDM_CONF="$LIGHTDM_DIR/50-uno-q-autologin.conf"
GETTY_DIR=/etc/systemd/system/getty@tty1.service.d
GETTY_CONF="$GETTY_DIR/50-uno-q-autologin.conf"

# The user who should be logged in. SUDO_USER is who invoked sudo, which is
# almost always the right answer - "root" never is.
if [ -z "$USER_NAME" ]; then
    USER_NAME=${SUDO_USER:-}
    [ -z "$USER_NAME" ] && USER_NAME=$(ls /home 2>/dev/null | head -1)
    [ -z "$USER_NAME" ] && USER_NAME=arduino
fi

# ------------------------------------------------------------------ status --
if [ "$ACTION" = status ]; then
    step "Autologin status"
    if [ -f "$LIGHTDM_CONF" ]; then
        ok "graphical: enabled for $(sed -n 's/^autologin-user=//p' "$LIGHTDM_CONF")"
    else
        say "  graphical: not configured by this script"
    fi
    if [ -f "$GETTY_CONF" ]; then
        ok "console tty1: enabled"
    else
        say "  console tty1: not configured by this script"
    fi
    exit 0
fi

# ----------------------------------------------------------------- disable --
if [ "$ACTION" = disable ]; then
    step "Restoring the login screen"
    removed=0
    [ -f "$LIGHTDM_CONF" ] && { rm -f "$LIGHTDM_CONF"; ok "removed $LIGHTDM_CONF"; removed=1; }
    if [ -f "$GETTY_CONF" ]; then
        rm -f "$GETTY_CONF"
        rmdir "$GETTY_DIR" 2>/dev/null || true
        systemctl daemon-reload
        ok "removed console autologin"
        removed=1
    fi
    [ "$removed" = 0 ] && say "  nothing to remove"
    say ""
    say "Reboot to apply:  sudo reboot"
    exit 0
fi

# ------------------------------------------------------------------ enable --
need_root "$@"
id "$USER_NAME" >/dev/null 2>&1 || die "no such user: $USER_NAME"

step "Enabling autologin for '$USER_NAME'"

DM=$(systemctl status display-manager 2>/dev/null \
     | head -1 | grep -oE 'lightdm|gdm3|gdm|sddm' || true)
[ -n "$DM" ] || DM=$(basename "$(readlink -f /etc/systemd/system/display-manager.service 2>/dev/null)" .service 2>/dev/null || true)

case "$DM" in
  lightdm|"")
    # A drop-in rather than editing lightdm.conf: the package owns that file
    # and an upgrade can replace it, silently taking the setting with it.
    mkdir -p "$LIGHTDM_DIR"
    {
        echo "# Written by uno-q-dsi-panel scripts/50-autologin.sh"
        echo "# Remove this file, or run the script with --disable, to restore"
        echo "# the login screen."
        echo "[Seat:*]"
        echo "autologin-user=$USER_NAME"
        echo "autologin-user-timeout=0"
    } > "$LIGHTDM_CONF"
    ok "lightdm: $LIGHTDM_CONF"
    ;;
  gdm3|gdm)
    warn "this board uses $DM, not lightdm - configure it in /etc/gdm3/daemon.conf:"
    say  "    [daemon]"
    say  "    AutomaticLoginEnable=true"
    say  "    AutomaticLogin=$USER_NAME"
    ;;
  *)
    warn "unrecognised display manager '$DM' - not touching it"
    ;;
esac

# Debian's lightdm-autologin PAM stack permits this without extra group
# membership, but some setups gate on an 'autologin' group. Join it when it
# exists; do not create one, since that would imply a policy this script has
# no business inventing.
if getent group autologin >/dev/null 2>&1; then
    usermod -aG autologin "$USER_NAME" 2>/dev/null || true
    ok "added $USER_NAME to the autologin group"
fi

if [ "$CONSOLE" = "1" ]; then
    mkdir -p "$GETTY_DIR"
    {
        echo "# Written by uno-q-dsi-panel scripts/50-autologin.sh"
        echo "[Service]"
        echo "ExecStart="
        echo "ExecStart=-/sbin/agetty --autologin $USER_NAME --noclear %I \$TERM"
    } > "$GETTY_CONF"
    systemctl daemon-reload
    ok "console tty1 also logs in automatically"
fi

record_state "autologin enabled for $USER_NAME"
say ""
warn "The login prompt is gone: anyone at the screen gets the desktop."
warn "Fine for workshop and demo boards; not for anything exposed."
say ""
say "Reboot to apply:   sudo reboot"
say "To undo:           sudo ./scripts/50-autologin.sh --disable"

#!/bin/sh
# Update an existing installation to the current checkout.
#
#   git pull && sudo ./update.sh
#
# Re-runs the parts that produce artefacts - drivers, DKMS registration, the
# overlay - without repeating the OS update or asking anything. Safe to run
# repeatedly; every step is idempotent.
#
# Use this after `git pull`, and after any kernel upgrade if DKMS was not
# registered (see scripts/25-install-dkms.sh).
set -e
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
. "$HERE/lib/common.sh"
need_root "$@"

PANEL_DEF=${1:-}
if [ -z "$PANEL_DEF" ]; then
    # Remember what was installed, so `sudo ./update.sh` needs no arguments.
    if [ -r /etc/default/uno-q-dsi-panel ]; then
        # shellcheck disable=SC1091
        . /etc/default/uno-q-dsi-panel
        [ -n "${PANEL_ID:-}" ] && PANEL_DEF="$HERE/panels/$PANEL_ID.panel"
    fi
fi
[ -n "$PANEL_DEF" ] && [ -f "$PANEL_DEF" ] || die \
    "cannot tell which panel is installed. Pass it explicitly:
    sudo ./update.sh panels/<your-panel>.panel"
PANEL_DEF=$(abspath "$PANEL_DEF")
load_panel "$PANEL_DEF"

VERSION=$(cat "$HERE/VERSION" 2>/dev/null || echo unknown)
step "Updating uno-q-dsi-panel to $VERSION"
say "  panel  : $PANEL_ID"
say "  kernel : $(uname -r)"

kernel_has_carrier_overlays || die \
    "Media Carrier overlays missing - this looks like a fresh board.
    Run the full installer instead:  sudo ./install.sh $PANEL_DEF"

# Rebuild from freshly fetched sources: a kernel change since the last install
# means different sources, and the fetch is keyed to the running kernel.
rm -rf "$BUILD_DIR"
sh "$HERE/scripts/20-build-drivers.sh"   "$PANEL_DEF"
sh "$HERE/scripts/25-install-dkms.sh"    "$PANEL_DEF"
sh "$HERE/scripts/30-install-overlay.sh" "$PANEL_DEF"
sh "$HERE/scripts/35-install-recovery.sh" "$PANEL_DEF"

step "Updated"
say "Reboot, then verify:"
say ""
say "    sudo reboot"
say "    sudo ./scripts/40-verify.sh \"$PANEL_DEF\""

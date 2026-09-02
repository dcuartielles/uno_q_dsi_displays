#!/bin/sh
# Undo everything install.sh did: restore the stock modules and Arduino's
# original overlay, and turn the display option off.
#
#   sudo ./uninstall.sh
set -e
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
. "$HERE/lib/common.sh"
need_root "$@"

K=$(uname -r)
MODDIR="/lib/modules/$K"

step "Restoring stock kernel modules"
for m in "$MODDIR/kernel/drivers/gpu/drm/panel/panel-simple.ko" \
         "$MODDIR/kernel/drivers/input/touchscreen/edt-ft5x06.ko"; do
    if [ -f "$m.distrib" ]; then
        mv -f "$m.distrib" "$m"
        ok "restored $(basename "$m")"
    else
        say "  $(basename "$m") was not replaced"
    fi
done

if [ -f "$MODDIR/extra/rpi-panel-attiny-regulator.ko" ]; then
    rm -f "$MODDIR/extra/rpi-panel-attiny-regulator.ko"
    ok "removed rpi-panel-attiny-regulator"
fi
rm -f /etc/modules-load.d/uno-q-dsi-panel.conf
depmod -a

step "Removing the boot-recovery service"
if [ -f /etc/systemd/system/uno-q-dsi-panel-recover.service ]; then
    systemctl disable --now uno-q-dsi-panel-recover.service >/dev/null 2>&1 || true
    rm -f /etc/systemd/system/uno-q-dsi-panel-recover.service
    systemctl daemon-reload
    ok "removed uno-q-dsi-panel-recover.service"
else
    say "  recovery service was not installed"
fi
rm -f /usr/local/libexec/uno-q-dsi-panel-recover /etc/default/uno-q-dsi-panel

step "Restoring Arduino's original 5-inch overlay"
if [ -f "$SLOT_BACKUP" ]; then
    mv -f "$SLOT_BACKUP" "$SLOT_DTBO"
    ok "restored $(basename "$SLOT_DTBO")"
else
    warn "no backup found - the slot still holds our overlay"
fi

step "Disabling the carrier display"
if have_cmd arduino-linux-config; then
    arduino-linux-config carrier enable media-carrier display=none || \
        warn "could not update the carrier configuration"
    ok "display set to none (USB-C DisplayPort will work again)"
fi

rm -rf "$STATE_DIR"
step "Done"
say "Reboot to apply:  sudo reboot"
say ""
say "Build artefacts are still in $BUILD_DIR - delete them if you want:"
say "    rm -rf $BUILD_DIR"

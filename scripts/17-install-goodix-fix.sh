#!/bin/sh
# Rebuild the Goodix touch driver with reads the CCI bus can actually carry.
#
#   sudo ./scripts/17-install-goodix-fix.sh panels/<a goodix panel>.panel
#
# Why this is needed at all
# ------------------------
# The Goodix panels need nothing else from this repository - Arduino ships the
# overlay and the kernel has every driver. But the touchscreen does not work,
# and it fails silently enough to look like hardware:
#
#     Goodix-TS 0-005d: Error reading 32 bytes from 0x8158: -95
#
# -95 is -EOPNOTSUPP. Qualcomm's CCI I2C controller is camera-oriented and
# refuses any read longer than 12 bytes. Measured on this board, one byte at a
# time:
#
#     read 12 bytes: OK        read 13 bytes: FAIL
#     read 16 bytes: FAIL      read 32 bytes: FAIL
#
# goodix.c reads a 32-byte contact report per touch and a 186-byte config table
# at probe. Both are refused, so the driver binds, creates an input device,
# reports no error at probe - and produces no events. Every check short of
# actually touching the screen passes.
#
# This is the same limitation edt-ft5x06 is patched for on the Waveshare
# panels; see tools/patch-edt-ft5x06.py, which splits a 33 to 63 byte read for
# exactly the same reason. Same controller, same ceiling, different touch chip,
# and it went unnoticed here for longer because every read Goodix does while
# probing is short enough to succeed.
#
# WHICH PANELS THIS AFFECTS
# -------------------------
# Every panel with a Goodix at 0x5d - the Arduino 5, 8, 10.1 and 12.3 inch. It
# was found on the 12.3 inch because that was the first one where anybody
# actually put a finger on the glass; the others were only ever checked for the
# presence of an input device, which is exactly what this fault leaves behind.
set -e
HERE=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
. "$HERE/lib/common.sh"
need_root "$@"

PANEL_DEF=${1:?usage: $0 <panel definition>}
[ -f "$PANEL_DEF" ] || die "no such panel definition: $PANEL_DEF"
PANEL_DEF=$(abspath "$PANEL_DEF")
load_panel "$PANEL_DEF"

K=$(uname -r)
MODDIR=/lib/modules/$K
[ -d "$MODDIR/build" ] || die "no kernel headers for $K - install linux-headers-$K"

COMMIT=$(printf '%s' "$K" | sed 's/.*-g//')
SRC_BASE="https://raw.githubusercontent.com/arduino/linux-qcom/$COMMIT"
BUILD=${BUILD_DIR:-$HOME/.uno-q-dsi-build}/goodix
mkdir -p "$BUILD"
cd "$BUILD"

step "Fetching the Goodix driver matching kernel $K"
# Three files, because goodix_ts is built from two objects plus a header. A
# Makefile of "obj-m += goodix.o" links but leaves three symbols undefined.
for f in goodix.c goodix.h goodix_fwupload.c; do
    if [ ! -s "$f.pristine" ]; then
        say "  fetching $f"
        curl -fsSL --max-time 120 \
            "$SRC_BASE/drivers/input/touchscreen/$f" -o "$f.pristine" \
            || die "could not fetch $f (kernel commit $COMMIT)"
    fi
    cp "$f.pristine" "$f"
done

step "Patching"
python3 "$HERE/tools/patch-goodix.py" goodix.c

step "Building"
printf 'obj-m += goodix_ts.o\ngoodix_ts-y := goodix.o goodix_fwupload.o\n' > Makefile
make -C "$MODDIR/build" M="$PWD" modules >/dev/null 2>build.log || {
    tail -30 build.log
    die "module build failed (see $BUILD/build.log)"
}
ok "goodix_ts built"

step "Installing"
P_GOODIX="$MODDIR/kernel/drivers/input/touchscreen/goodix_ts.ko"
backup_module "$P_GOODIX"
install -D -m 644 goodix_ts.ko "$MODDIR/updates/goodix_ts.ko"
depmod -a
ok "goodix_ts installed (original kept as goodix_ts.ko.distrib)"

record_state "goodix touch driver rebuilt with CCI-sized reads"

say ""
say "${C_BLD}Reboot to load it${C_OFF}, then touch the screen - not just check that an"
say "input device exists, because this fault leaves one behind:"
say ""
say "    sudo reboot"
say "    sudo ./scripts/test-touch.sh"

#!/bin/sh
# Fetch, patch and install the kernel modules this panel needs.
#
#   sudo ./scripts/20-build-drivers.sh panels/<your-panel>.panel
#
# Three modules:
#   panel-simple               - gains a descriptor for your panel (replaced)
#   edt-ft5x06                 - polling + short I2C reads   (replaced, optional)
#   rpi-panel-attiny-regulator - not in this kernel at all   (new, in extra/)
#
# Originals are kept as <module>.ko.distrib and restored by uninstall.sh.
set -e
HERE=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
. "$HERE/lib/common.sh"
need_root "$@"

PANEL_DEF=${1:?usage: $0 <panel definition>}
[ -f "$PANEL_DEF" ] || die "no such panel definition: $PANEL_DEF"
# absolute, because we cd into the build directory below
PANEL_DEF=$(abspath "$PANEL_DEF")
load_panel "$PANEL_DEF"

K=$(uname -r)
MODDIR="/lib/modules/$K"
[ -d "$MODDIR" ] || die "no module directory for kernel $K"

# The kernel source commit is embedded in the kernel release string, so we can
# fetch driver sources that exactly match the running kernel.
COMMIT=$(printf '%s' "$K" | sed -n 's/.*-g\([0-9a-f]\{6,\}\).*/\1/p')
[ -n "$COMMIT" ] || die "cannot derive a source commit from kernel release '$K'"
SRC_BASE="${SRC_BASE:-https://raw.githubusercontent.com/arduino/linux-qcom/$COMMIT}"

step "Build environment"
if [ ! -d "$MODDIR/build" ]; then
    say "  installing kernel headers and toolchain..."
    apt-get update
    DEBIAN_FRONTEND=noninteractive apt-get -y install \
        "linux-headers-$K" build-essential bc python3 device-tree-compiler
fi
[ -d "$MODDIR/build" ] || die "kernel headers for $K are not available"
ok "headers: $MODDIR/build"
have_cmd python3 || die "python3 is required"
have_cmd dtc || die "device-tree-compiler is required"

mkdir -p "$BUILD_DIR"
cd "$BUILD_DIR"

fetch() { # fetch <path-in-tree> <local>
    [ -s "$2" ] && return 0
    say "  fetching $2"
    curl -fsSL --max-time 120 "$SRC_BASE/$1" -o "$2" \
        || die "could not fetch $1 (kernel commit $COMMIT)"
}

step "Fetching driver sources matching kernel $K"
fetch drivers/gpu/drm/panel/panel-simple.c            panel-simple.c
fetch drivers/regulator/rpi-panel-attiny-regulator.c  rpi-panel-attiny-regulator.c
[ -n "$TOUCH_ADDR" ] && fetch drivers/input/touchscreen/edt-ft5x06.c edt-ft5x06.c
for f in panel-simple.c rpi-panel-attiny-regulator.c edt-ft5x06.c; do
    [ -s "$f" ] && [ ! -s "$f.pristine" ] && cp "$f" "$f.pristine"
done
for f in panel-simple.c rpi-panel-attiny-regulator.c edt-ft5x06.c; do
    [ -s "$f.pristine" ] && cp "$f.pristine" "$f"
done

step "Patching"
python3 "$HERE/tools/gen-panel-patch.py" panel-simple.c "$PANEL_DEF"
python3 "$HERE/tools/patch-attiny-regulator.py" rpi-panel-attiny-regulator.c
[ -n "$TOUCH_ADDR" ] && python3 "$HERE/tools/patch-edt-ft5x06.py" edt-ft5x06.c

step "Building"
{
    echo "obj-m += panel-simple.o"
    echo "obj-m += rpi-panel-attiny-regulator.o"
    [ -n "$TOUCH_ADDR" ] && echo "obj-m += edt-ft5x06.o"
} > Makefile
make -C "$MODDIR/build" M="$PWD" modules >/dev/null 2>build.log || {
    tail -30 build.log; die "module build failed (see $BUILD_DIR/build.log)";
}
ok "modules built"

step "Installing"
P_PANEL="$MODDIR/kernel/drivers/gpu/drm/panel/panel-simple.ko"
backup_module "$P_PANEL"; cp panel-simple.ko "$P_PANEL"
ok "panel-simple (original kept as panel-simple.ko.distrib)"

mkdir -p "$MODDIR/extra"
cp rpi-panel-attiny-regulator.ko "$MODDIR/extra/"
ok "rpi-panel-attiny-regulator (new module)"

if [ -n "$TOUCH_ADDR" ]; then
    P_TOUCH="$MODDIR/kernel/drivers/input/touchscreen/edt-ft5x06.ko"
    backup_module "$P_TOUCH"; cp edt-ft5x06.ko "$P_TOUCH"
    ok "edt-ft5x06 (original kept as edt-ft5x06.ko.distrib)"
fi

printf 'rpi-panel-attiny-regulator\n' > /etc/modules-load.d/uno-q-dsi-panel.conf
depmod -a
record_state "drivers built for kernel $K from commit $COMMIT"
ok "modules installed and depmod run"

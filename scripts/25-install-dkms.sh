#!/bin/sh
# Register the patched drivers with DKMS so they survive a kernel upgrade.
#
#   sudo ./scripts/25-install-dkms.sh panels/<your-panel>.panel
#
# Why this matters
# ----------------
# The modules are built against one kernel version. Without DKMS, the next
# `apt upgrade` that pulls a new kernel leaves the user with a BLACK SCREEN and
# nothing to explain it - the same invisible failure this project exists to
# fix, reintroduced by routine maintenance. Documentation is not a mechanism.
#
# With DKMS the modules are rebuilt automatically when a kernel is installed,
# and if the rebuild fails it fails LOUDLY at upgrade time instead of silently
# at the next boot.
#
# What gets registered
# --------------------
# The already-patched sources, not the patch tools. Rebuilding does not need
# the network, and does not depend on GitHub still serving the same commit
# months from now. If a future kernel changes an API the build fails visibly,
# and the fix is to re-run install.sh, which fetches and patches sources
# matching that kernel.
#
# DKMS installs into /lib/modules/<ver>/updates/dkms/, which modprobe prefers
# over kernel/, so the patched panel-simple and edt-ft5x06 win without the
# distribution's own files being touched.
set -e
HERE=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
. "$HERE/lib/common.sh"
need_root "$@"

PANEL_DEF=${1:?usage: $0 <panel definition>}
[ -f "$PANEL_DEF" ] || die "no such panel definition: $PANEL_DEF"
PANEL_DEF=$(abspath "$PANEL_DEF")
load_panel "$PANEL_DEF"

VERSION=$(cat "$HERE/VERSION" 2>/dev/null || echo 0.0.0)
NAME=uno-q-dsi-panel
SRC="/usr/src/$NAME-$VERSION"

step "Registering the drivers with DKMS"

if ! have_cmd dkms; then
    say "  installing dkms..."
    DEBIAN_FRONTEND=noninteractive apt-get -y install dkms >/dev/null 2>&1 || \
        die "could not install dkms"
fi

[ -s "$BUILD_DIR/rpi-panel-attiny-regulator.c" ] || \
    die "patched sources not found in $BUILD_DIR - run scripts/20-build-drivers.sh first"

# Remove any previous registration of this version before rewriting the tree.
if dkms status "$NAME/$VERSION" 2>/dev/null | grep -q "$NAME"; then
    dkms remove "$NAME/$VERSION" --all >/dev/null 2>&1 || true
fi

rm -rf "$SRC"
mkdir -p "$SRC"
for f in panel-simple.c rpi-panel-attiny-regulator.c edt-ft5x06.c; do
    [ -s "$BUILD_DIR/$f" ] && cp "$BUILD_DIR/$f" "$SRC/"
done

# The module list has to match what was actually patched: a panel with no
# touch controller never builds edt-ft5x06.
MODULES="panel-simple rpi-panel-attiny-regulator"
[ -s "$SRC/edt-ft5x06.c" ] && MODULES="$MODULES edt-ft5x06"

{
    for m in $MODULES; do echo "obj-m += $m.o"; done
    echo ""
    echo "KVER ?= \$(shell uname -r)"
    echo "KDIR ?= /lib/modules/\$(KVER)/build"
    echo ""
    echo "all:"
    echo "	\$(MAKE) -C \$(KDIR) M=\$(PWD) modules"
    echo ""
    echo "clean:"
    echo "	\$(MAKE) -C \$(KDIR) M=\$(PWD) clean"
} > "$SRC/Makefile"

{
    echo "PACKAGE_NAME=\"$NAME\""
    echo "PACKAGE_VERSION=\"$VERSION\""
    echo "MAKE[0]=\"make -C \$dkms_source_tree KVER=\$kernelver KDIR=/lib/modules/\$kernelver/build\""
    echo "CLEAN=\"make -C \$dkms_source_tree clean KVER=\$kernelver\""
    i=0
    for m in $MODULES; do
        echo "BUILT_MODULE_NAME[$i]=\"$m\""
        # updates/dkms takes precedence over kernel/, which is how the patched
        # panel-simple and edt-ft5x06 override the distribution's copies.
        echo "DEST_MODULE_LOCATION[$i]=\"/updates/dkms\""
        i=$((i + 1))
    done
    echo "AUTOINSTALL=\"yes\""
    echo "REMAKE_INITRD=\"no\""
} > "$SRC/dkms.conf"

ok "source tree: $SRC"
say "  modules: $MODULES"

step "Building through DKMS for $(uname -r)"
dkms add -m "$NAME" -v "$VERSION" >/dev/null 2>&1 || true
if dkms build -m "$NAME" -v "$VERSION" >/dev/null 2>&1; then
    ok "built"
else
    warn "DKMS build failed - showing the tail of its log"
    tail -20 "/var/lib/dkms/$NAME/$VERSION/build/make.log" 2>/dev/null || true
    die "DKMS build failed"
fi

dkms install -m "$NAME" -v "$VERSION" --force >/dev/null 2>&1 || \
    die "DKMS install failed"
depmod -a
record_state "dkms $NAME/$VERSION registered"
ok "installed into /lib/modules/$(uname -r)/updates/dkms/"

say ""
dkms status "$NAME/$VERSION" 2>/dev/null | sed 's/^/  /'
say ""
say "The modules will now be rebuilt automatically when a new kernel is"
say "installed. If a future kernel changes a driver API the rebuild fails"
say "visibly at upgrade time - re-run install.sh to fetch and patch sources"
say "matching that kernel."

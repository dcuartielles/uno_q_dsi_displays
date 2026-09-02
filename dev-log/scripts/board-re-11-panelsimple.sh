#!/bin/sh
# Runs ON the UNO Q. Stdin secrets contract: 1. sudo password  2. SSID  3. wifi pw
#
# RPi drives this panel as a DIRECT DSI panel with no bridge, using their
# generic "panel-dsi" binding in panel-simple. Mainline has neither the binding
# nor the driver support. Rather than backport the whole DT-driven path, add a
# fixed descriptor for this panel to mainline panel-simple, with RPi's exact
# numbers from vc4-kms-dsi-waveshare-800x480-overlay.dts:
#
#   clock 27.777 MHz   hfp 59  hsync 2  hbp 45
#   vfp 7  vsync 2  vbp 22     RGB888, MODE_VIDEO, 1 lane
unset HISTFILE
IFS= read -r SUDO_PASS; SUDO_PASS=$(printf '%s' "$SUDO_PASS" | tr -d '\r')
IFS= read -r WIFI_SSID
IFS= read -r WIFI_PASS
S() { printf '%s\n' "$SUDO_PASS" | sudo -S -p '' "$@"; }
S true 2>/dev/null || { echo "SUDO PASSWORD REJECTED"; exit 1; }

K=$(uname -r)
SRC="$HOME/panel-build"
cd "$SRC" || exit 1
MLN=https://raw.githubusercontent.com/arduino/linux-qcom/122c2c22d838

[ -s panel-simple.c ] || curl -fsSL --max-time 120 "$MLN/drivers/gpu/drm/panel/panel-simple.c" -o panel-simple.c 2>/dev/null
[ -s panel-simple.c.orig ] || cp panel-simple.c panel-simple.c.orig
cp panel-simple.c.orig panel-simple.c
printf 'panel-simple.c: %s lines\n' "$(wc -l < panel-simple.c)"

python3 - <<'PY'
import re
p = 'panel-simple.c'
s = open(p).read()

# locate the DSI of_match table
m = re.search(r'static const struct of_device_id dsi_of_match\[\] = \{', s)
assert m, "dsi_of_match table not found"

entry = '''/*
 * Waveshare 800x480 DSI panel (ICN6211 bridge on-panel, self-configuring).
 * Timings taken verbatim from Raspberry Pi's
 * arch/arm/boot/dts/overlays/vc4-kms-dsi-waveshare-800x480-overlay.dts
 *   clock-frequency 27777000, hfp 59, hsync 2, hbp 45, vfp 7, vsync 2, vbp 22
 */
static const struct drm_display_mode waveshare_800x480_mode = {
\t.clock = 27777,
\t.hdisplay = 800,
\t.hsync_start = 800 + 59,
\t.hsync_end = 800 + 59 + 2,
\t.htotal = 800 + 59 + 2 + 45,
\t.vdisplay = 480,
\t.vsync_start = 480 + 7,
\t.vsync_end = 480 + 7 + 2,
\t.vtotal = 480 + 7 + 2 + 22,
};

static const struct panel_desc_dsi waveshare_800x480 = {
\t.desc = {
\t\t.modes = &waveshare_800x480_mode,
\t\t.num_modes = 1,
\t\t.bpc = 8,
\t\t.size = {
\t\t\t.width = 109,
\t\t\t.height = 65,
\t\t},
\t\t.connector_type = DRM_MODE_CONNECTOR_DSI,
\t},
\t.flags = MIPI_DSI_MODE_VIDEO,
\t.format = MIPI_DSI_FMT_RGB888,
\t.lanes = 1,
};

'''
s = s[:m.start()] + entry + s[m.start():]

# add the of_match entry
old = 'static const struct of_device_id dsi_of_match[] = {\n'
new = old + '\t{\n\t\t.compatible = "waveshare,4-3-inch-dsi",\n\t\t.data = &waveshare_800x480\n\t}, {\n'
assert s.count(old) == 1
s = s.replace(old, new, 1)

open(p, 'w').write(s)
print("patched panel-simple.c: added waveshare,4-3-inch-dsi")
PY

echo
echo "=== verify the patch ==="
grep -n -A6 'waveshare_800x480_mode = {' panel-simple.c | head -14
grep -n -B1 -A3 'waveshare,4-3-inch-dsi' panel-simple.c | head -10

echo
echo "=== add to the build ==="
grep -q 'panel-simple' Makefile || sed -i '1i obj-m += panel-simple.o' Makefile
cat Makefile

echo
echo "=== build ==="
make -C "/lib/modules/$K/build" M="$PWD" modules 2>&1 | tail -12
ls -la panel-simple.ko 2>/dev/null || { echo ">>> BUILD FAILED"; exit 1; }

echo
echo "=== install: replace the in-tree panel-simple (original backed up) ==="
INTREE="/lib/modules/$K/kernel/drivers/gpu/drm/panel/panel-simple.ko"
S sh -c "[ -f '$INTREE.distrib' ] || cp '$INTREE' '$INTREE.distrib'"
S cp panel-simple.ko "$INTREE"
S depmod -a
echo "--- does it now claim our compatible? ---"
grep -i 'waveshare' /lib/modules/"$K"/modules.alias | head

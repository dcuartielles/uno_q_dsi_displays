#!/bin/sh
# Runs ON the UNO Q. Stdin secrets contract: 1. sudo password  2. SSID  3. wifi pw
# Fixed version: consume the original table's opening brace so the entry splices
# in correctly instead of leaving a duplicate '{'.
unset HISTFILE
IFS= read -r SUDO_PASS; SUDO_PASS=$(printf '%s' "$SUDO_PASS" | tr -d '\r')
IFS= read -r WIFI_SSID
IFS= read -r WIFI_PASS
S() { printf '%s\n' "$SUDO_PASS" | sudo -S -p '' "$@"; }
S true 2>/dev/null || { echo "SUDO PASSWORD REJECTED"; exit 1; }

K=$(uname -r)
SRC="$HOME/panel-build"
cd "$SRC" || exit 1
cp panel-simple.c.orig panel-simple.c

python3 - <<'PY'
import re
p = 'panel-simple.c'
s = open(p).read()

m = re.search(r'static const struct of_device_id dsi_of_match\[\] = \{', s)
assert m, "dsi_of_match not found"

entry = '''/*
 * Waveshare 800x480 DSI panel. The on-panel ICN6211 DSI-to-RGB bridge
 * self-configures, so the panel is driven directly as a DSI device with no
 * bridge node - this is how Raspberry Pi does it. Timings verbatim from
 * arch/arm/boot/dts/overlays/vc4-kms-dsi-waveshare-800x480-overlay.dts
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

# consume the original opening brace of the first entry, then re-emit it
old = 'static const struct of_device_id dsi_of_match[] = {\n\t{\n'
new = ('static const struct of_device_id dsi_of_match[] = {\n'
       '\t{\n'
       '\t\t.compatible = "waveshare,4-3-inch-dsi",\n'
       '\t\t.data = &waveshare_800x480\n'
       '\t}, {\n')
assert s.count(old) == 1, "anchor not unique: %d" % s.count(old)
s = s.replace(old, new, 1)

open(p, 'w').write(s)
print("patched cleanly")
PY

echo
echo "=== verify the table splices correctly ==="
sed -n '/static const struct of_device_id dsi_of_match/,+12p' panel-simple.c

echo
echo "=== build ==="
make -C "/lib/modules/$K/build" M="$PWD" modules 2>&1 | tail -10
ls -la panel-simple.ko 2>/dev/null || { echo ">>> BUILD FAILED"; exit 1; }

echo
echo "=== install (in-tree original backed up as .distrib) ==="
INTREE="/lib/modules/$K/kernel/drivers/gpu/drm/panel/panel-simple.ko"
S sh -c "[ -f '$INTREE.distrib' ] || cp '$INTREE' '$INTREE.distrib'"
S cp panel-simple.ko "$INTREE"
S depmod -a
echo "--- claims our compatible now? ---"
grep -i 'waveshare,4-3-inch-dsi' /lib/modules/"$K"/modules.alias

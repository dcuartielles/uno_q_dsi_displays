#!/usr/bin/env python3
"""Insert a panel descriptor into panel-simple.c from a .panel definition.

Mainline's panel-simple has no generic "panel-dsi" device-tree binding (that
is a Raspberry Pi addition), so instead of backporting the whole DT-driven
path we add a fixed descriptor for the panel and match it by compatible.

Usage: gen-panel-patch.py <panel-simple.c> <panel.def.sh>
Edits panel-simple.c in place. Idempotent: re-running replaces the block.
"""
import re
import subprocess
import sys

MARK_BEGIN = "/* --- BEGIN uno-q-dsi-panel generated --- */"
MARK_END = "/* --- END uno-q-dsi-panel generated --- */"


def load_def(path):
    """Source the shell definition and read the variables back out."""
    keys = ["PANEL_COMPATIBLE", "PANEL_C_NAME", "CLOCK_KHZ", "HACTIVE",
            "HFRONT", "HSYNC", "HBACK", "VACTIVE", "VFRONT", "VSYNC", "VBACK",
            "WIDTH_MM", "HEIGHT_MM", "DSI_LANES", "DSI_FORMAT",
            "DSI_MODE_FLAGS", "BPC"]
    script = ". '%s'; " % path + "; ".join(
        'printf "%%s=%%s\\n" %s "$%s"' % (k, k) for k in keys)
    out = subprocess.run(["sh", "-c", script], capture_output=True, text=True,
                         check=True).stdout
    d = {}
    for line in out.splitlines():
        k, _, v = line.partition("=")
        d[k] = v
    missing = [k for k in keys if not d.get(k)]
    if missing:
        sys.exit("panel definition is missing: %s" % ", ".join(missing))
    return d


def render(d):
    name = d["PANEL_C_NAME"]
    hs_start = int(d["HACTIVE"]) + int(d["HFRONT"])
    hs_end = hs_start + int(d["HSYNC"])
    htotal = hs_end + int(d["HBACK"])
    vs_start = int(d["VACTIVE"]) + int(d["VFRONT"])
    vs_end = vs_start + int(d["VSYNC"])
    vtotal = vs_end + int(d["VBACK"])
    return f"""{MARK_BEGIN}
/*
 * Generated from a .panel definition by tools/gen-panel-patch.py.
 * Do not edit by hand - edit the .panel file and re-run install.sh.
 */
static const struct drm_display_mode {name}_mode = {{
\t.clock = {d['CLOCK_KHZ']},
\t.hdisplay = {d['HACTIVE']},
\t.hsync_start = {hs_start},
\t.hsync_end = {hs_end},
\t.htotal = {htotal},
\t.vdisplay = {d['VACTIVE']},
\t.vsync_start = {vs_start},
\t.vsync_end = {vs_end},
\t.vtotal = {vtotal},
}};

static const struct panel_desc_dsi {name} = {{
\t.desc = {{
\t\t.modes = &{name}_mode,
\t\t.num_modes = 1,
\t\t.bpc = {d['BPC']},
\t\t.size = {{
\t\t\t.width = {d['WIDTH_MM']},
\t\t\t.height = {d['HEIGHT_MM']},
\t\t}},
\t\t.connector_type = DRM_MODE_CONNECTOR_DSI,
\t}},
\t.flags = {d['DSI_MODE_FLAGS']},
\t.format = {d['DSI_FORMAT']},
\t.lanes = {d['DSI_LANES']},
}};
{MARK_END}

"""


def main():
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    src, definition = sys.argv[1], sys.argv[2]
    d = load_def(definition)

    s = open(src).read()

    # make idempotent: drop any previously generated block and match entry
    s = re.sub(re.escape(MARK_BEGIN) + r".*?" + re.escape(MARK_END) + r"\n\n",
               "", s, flags=re.S)
    s = re.sub(r"\t\{\n\t\t\.compatible = \"[^\"]*\",\n\t\t\.data = &\w+\n"
               r"\t\}, \{ /\* uno-q-dsi-panel \*/\n",
               "\t{\n", s)

    m = re.search(r"static const struct of_device_id dsi_of_match\[\] = \{\n\t\{\n", s)
    if not m:
        sys.exit("could not find the DSI of_device_id table in %s" % src)

    s = s[:m.start()] + render(d) + s[m.start():]

    old = "static const struct of_device_id dsi_of_match[] = {\n\t{\n"
    new = ("static const struct of_device_id dsi_of_match[] = {\n"
           "\t{\n"
           f"\t\t.compatible = \"{d['PANEL_COMPATIBLE']}\",\n"
           f"\t\t.data = &{d['PANEL_C_NAME']}\n"
           "\t}, { /* uno-q-dsi-panel */\n")
    if s.count(old) != 1:
        sys.exit("unexpected of_device_id table layout (found %d anchors)"
                 % s.count(old))
    s = s.replace(old, new, 1)

    open(src, "w").write(s)
    print("  added %s (%s) to panel-simple"
          % (d["PANEL_C_NAME"], d["PANEL_COMPATIBLE"]))


if __name__ == "__main__":
    main()

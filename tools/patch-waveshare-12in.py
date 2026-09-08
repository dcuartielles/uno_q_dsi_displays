#!/usr/bin/env python3
"""Cut Raspberry Pi's Waveshare DSI panel driver down to the 12.3 inch alone.

The UNO Q kernel has no entry for the 12.3 inch DSI-TOUCH-A. Raspberry Pi's
tree does - mode, DSI parameters and the vendor initialisation sequence - and
that driver compiles against the Arduino kernel unmodified. So the panel does
not need a new driver written, only that one made safe to install here.

WHY IT CANNOT BE INSTALLED AS-IS
--------------------------------
It matches seventeen compatible strings, and three of them are the panels this
board already supports:

    waveshare,5.0-dsi-touch-a     the Arduino 5 inch
    waveshare,8.0-dsi-touch-a     the Arduino 8 inch
    waveshare,10.1-dsi-touch-a    the Arduino 10.1 inch

Those are driven by drivers already built into the UNO Q kernel - the 5 inch by
panel-himax-hx8394, the other two by jadard-jd9365da. Installing a module that
also claims them invites it to bind first, in which case a working panel gets
another driver's initialisation sequence. That is the failure this repository
has already met twice, and there is no reason to introduce a third way in.

So everything except the 12.3 inch is removed, and the driver is renamed. What
is left claims exactly one compatible string, which nothing else on this board
answers to.

WHY REMOVE RATHER THAN JUST TRIM THE MATCH TABLE
------------------------------------------------
Cutting the table alone leaves the other panels' mode tables and initialisation
sequences defined and unreferenced, and the kernel builds with -Werror. The
data has to go with the entries.

Usage: patch-waveshare-12in.py <panel-waveshare-dsi-v2.c>
"""
import io
import re
import sys

# The three symbols belonging to the 12.3 inch, which are what we keep.
KEEP = (
    "ws_panel_12_3_a_4lane_init",
    "ws_panel_12_3_a_4lane_mode",
    "ws_panel_12_3_inch_a_4lane_desc",
)

# The one compatible string this driver should answer to afterwards.
COMPATIBLE = "waveshare,12.3-dsi-touch-a,4lane"

BLOCK_START = re.compile(
    r"^static const struct (?:panel_init_cmd|drm_display_mode|ws_panel_desc) "
    r"(\w+)")


def drop_other_panels(lines):
    """Delete every per-panel data block except the 12.3 inch ones."""
    out, i, dropped = [], 0, []
    while i < len(lines):
        m = BLOCK_START.match(lines[i])
        if m and m.group(1) not in KEEP:
            name = m.group(1)
            # Blocks are top-level and close with "};" in column zero.
            while i < len(lines) and not lines[i].startswith("};"):
                i += 1
            i += 1                      # step past the closing brace
            while i < len(lines) and lines[i].strip() == "":
                i += 1                  # and the blank line after it
            dropped.append(name)
            continue
        out.append(lines[i])
        i += 1
    return out, dropped


def main():
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    path = sys.argv[1]

    with io.open(path, encoding="utf-8", newline="") as fh:
        text = fh.read()

    if "uno-q-dsi-panel" in text:
        print("  waveshare 12.3in driver already patched")
        return

    lines = text.split("\n")
    lines, dropped = drop_other_panels(lines)
    if not dropped:
        sys.exit("nothing was dropped - has the driver been restructured?")
    text = "\n".join(lines)

    # One entry in the match table, and nothing else.
    m = re.search(r"static const struct of_device_id .*?\{.*?\n\};\n",
                  text, re.S)
    if not m:
        sys.exit("of_match_table not found")
    table = m.group(0)
    name = re.search(r"static const struct of_device_id (\w+)", table).group(1)
    text = text.replace(table,
                        "static const struct of_device_id %s[] = {\n"
                        "\t{ .compatible = \"%s\",\n"
                        "\t  &%s },\n"
                        "\t{ /* sentinel */ }\n"
                        "};\n" % (name, COMPATIBLE, KEEP[2]), 1)

    # Rename, so it is obvious in lsmod and dmesg which driver this is and
    # where it came from, and so it cannot be confused with a stock one.
    text = text.replace('.name\t\t= "waveshare-dsi",',
                        '.name\t\t= "waveshare-dsi-12in",', 1)
    text = text.replace('MODULE_DESCRIPTION("Waveshare DSI panel driver");',
                        'MODULE_DESCRIPTION("Waveshare 12.3in DSI panel '
                        '(trimmed by uno-q-dsi-panel)");', 1)

    text = "/* patched by uno-q-dsi-panel: 12.3 inch only */\n" + text

    with io.open(path, "w", encoding="utf-8", newline="\n") as fh:
        fh.write(text)

    print("  waveshare 12.3in: kept %s, dropped %d other panel blocks"
          % (KEEP[2], len(dropped)))
    left = sorted(set(re.findall(r'"(waveshare,[^"]+)"', text)))
    print("  compatibles now claimed: %s" % (", ".join(left) or "none"))


if __name__ == "__main__":
    main()

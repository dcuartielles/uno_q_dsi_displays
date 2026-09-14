#!/usr/bin/env python3
"""Cut Raspberry Pi's Waveshare DSI panel driver down to a single panel.

    PANEL_DT_COMPATIBLE="waveshare,4.0-dsi-touch-c" \\
        patch-waveshare-panel.py panel-waveshare-dsi-v2.c

The UNO Q kernel has a mode for three Waveshare panels. Raspberry Pi's tree has
seventeen, with the vendor initialisation sequence for each, and that driver
compiles against the Arduino kernel unmodified. So most Waveshare panels need
no driver written - only that one made safe to install here.

WHY IT CANNOT BE INSTALLED AS-IS
--------------------------------
It matches seventeen compatible strings, and three of them are panels this
board already drives with built-in drivers:

    waveshare,5.0-dsi-touch-a     the Arduino 5 inch    (panel-himax-hx8394)
    waveshare,8.0-dsi-touch-a     the Arduino 8 inch    (jadard-jd9365da)
    waveshare,10.1-dsi-touch-a    the Arduino 10.1 inch (jadard-jd9365da)

Installing a module that also claims those invites it to bind first, in which
case a working panel gets another driver's initialisation sequence. That is a
failure this repository has met more than once, and there is no reason to
introduce another way in.

WHY THE SYMBOLS ARE DERIVED RATHER THAN LISTED
----------------------------------------------
An earlier version of this named the three symbols for its one panel directly.
That works exactly once. The driver holds a descriptor per panel, and each
descriptor names its own mode and initialisation sequence, so the whole set can
be read out of the source given nothing but the compatible string:

    of_match_table  compatible -> descriptor
    descriptor      .init      -> initialisation sequence
    descriptor      .mode      -> display mode

which means any of the seventeen can be extracted without editing this file.

WHY REMOVE THE OTHERS RATHER THAN JUST TRIM THE MATCH TABLE
-----------------------------------------------------------
Cutting the table alone leaves the other panels' modes and initialisation
sequences defined and unreferenced, and the kernel builds with -Werror. The
data has to go with the entries.
"""
import io
import os
import re
import sys

BLOCK_START = re.compile(
    r"^static const struct (?:panel_init_cmd|drm_display_mode|ws_panel_desc) "
    r"(\w+)")


def find_descriptor(text, compatible):
    """The descriptor symbol that this compatible string selects."""
    # Entries wrap onto a second line when the name is long, so the match
    # cannot assume both sit together.
    m = re.search(r'\{\s*\.compatible\s*=\s*"' + re.escape(compatible) +
                  r'"\s*,\s*&(\w+)\s*\}', text, re.S)
    if not m:
        raise SystemExit(
            "compatible %r is not in this driver.\n"
            "Available:\n  %s" % (compatible, "\n  ".join(
                sorted(set(re.findall(r'"(waveshare,[^"]+)"', text))))))
    return m.group(1)


def descriptor_symbols(text, desc):
    """The .init and .mode symbols a descriptor points at."""
    m = re.search(r"static const struct ws_panel_desc " + re.escape(desc) +
                  r"\s*=\s*\{(.*?)\n\};", text, re.S)
    if not m:
        raise SystemExit("descriptor %s not found" % desc)
    body = m.group(1)
    init = re.search(r"\.init\s*=\s*(\w+)", body)
    mode = re.search(r"\.mode\s*=\s*&?(\w+)", body)
    if not (init and mode):
        raise SystemExit("could not read .init/.mode out of %s" % desc)
    return init.group(1), mode.group(1)


def drop_other_panels(lines, keep):
    """Delete every per-panel data block except the ones we keep."""
    out, i, dropped = [], 0, []
    while i < len(lines):
        m = BLOCK_START.match(lines[i])
        if m and m.group(1) not in keep:
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

    compatible = os.environ.get("PANEL_DT_COMPATIBLE", "")
    if not compatible:
        sys.exit("PANEL_DT_COMPATIBLE is required")

    # The string the trimmed driver will answer to, which is deliberately NOT
    # the upstream one: built-in drivers claim several of those, and if one of
    # them binds first it gets an overlay shaped for a different driver. Using
    # a private string means the module and the overlay can only match each
    # other.
    installed = os.environ.get("PANEL_DT_COMPATIBLE_OUT", "") or compatible

    with io.open(path, encoding="utf-8", newline="") as fh:
        text = fh.read()

    if "uno-q-dsi-panel" in text:
        print("  waveshare driver already patched")
        return

    desc = find_descriptor(text, compatible)
    init, mode = descriptor_symbols(text, desc)
    keep = (init, mode, desc)

    lines, dropped = drop_other_panels(text.split("\n"), keep)
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
    text = text.replace(
        table,
        "static const struct of_device_id %s[] = {\n"
        "\t{ .compatible = \"%s\",\n"
        "\t  &%s },\n"
        "\t{ /* sentinel */ }\n"
        "};\n" % (name, installed, desc), 1)

    # Rename, so lsmod and dmesg say which driver this is and where it came
    # from, and so it cannot be confused with a stock one.
    tag = re.sub(r"[^a-z0-9]+", "-", installed.split(",", 1)[1].lower()).strip("-")
    text = text.replace('.name\t\t= "waveshare-dsi",',
                        '.name\t\t= "ws-%s",' % tag, 1)
    text = text.replace('MODULE_DESCRIPTION("Waveshare DSI panel driver");',
                        'MODULE_DESCRIPTION("Waveshare %s DSI panel '
                        '(trimmed by uno-q-dsi-panel)");' % compatible, 1)

    text = ("/* patched by uno-q-dsi-panel: %s only, claimed as %s */\n"
            % (compatible, installed)) + text

    with io.open(path, "w", encoding="utf-8", newline="\n") as fh:
        fh.write(text)

    print("  waveshare: kept %s (%s, %s)" % (desc, mode, init))
    print("  dropped %d other panel blocks" % len(dropped))
    left = sorted(set(re.findall(r'"(waveshare,[^"]+)"', text)))
    print("  compatibles now claimed: %s"
          % (", ".join(left) if left else installed))
    if installed != compatible:
        print("  claimed as %s, so nothing built in can race for it" % installed)


if __name__ == "__main__":
    main()

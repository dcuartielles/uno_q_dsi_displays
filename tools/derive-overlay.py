#!/usr/bin/env python3
"""Turn one of Arduino's panel overlays into one for a different panel.

Reads a decompiled .dts in place. Configured entirely through the environment,
so the caller (scripts/16-install-derived-panel.sh) can drive it from a .panel
file without this script needing to parse one.

    PANEL_DT_COMPATIBLE   the compatible string the new driver matches
    RESET_GPIO_LINE       GPIO line on the panel's controller, default 1
    IOVCC_GPIO_LINE       default 4
    AVDD_GPIO_LINE        default 0
    TOUCH_SWAP_XY         1 to add touchscreen-swapped-x-y
    TOUCH_INVERT_X        1 to add touchscreen-inverted-x
    TOUCH_INVERT_Y        1 to add touchscreen-inverted-y

WHY THE POWER RAILS MOVE FROM REGULATORS TO GPIOS
-------------------------------------------------
Arduino's overlay hands the panel two regulators, vccio-supply and vdd-supply,
and its built-in jadard driver enables them. Raspberry Pi's driver instead asks
for iovcc-gpio and avdd-gpio and sequences them itself - iovcc, 20 ms, avdd,
20 ms, then a reset pulse.

Handing that driver regulators leaves it nothing to sequence, and worse: a
regulator-fixed node OWNS the GPIO, so the driver's own request for the same
line is refused. Both regulator nodes therefore have to go, and the lines are
handed to the panel node directly.

Getting this wrong is quiet. The panel came up connected, at the right mode,
with the driver bound and the backlight at 255 - and stayed completely dark,
photographing identically at brightness 0 and 255.

AND WHY RESET POLARITY FLIPS
----------------------------
Same line, opposite flag:

    Arduino        reset-gpio = <&mcu 1 GPIO_ACTIVE_LOW>
    Raspberry Pi   reset-gpio = <&mcu 1 GPIO_ACTIVE_HIGH>

so the driver's pulse comes out inverted and the panel sits held in reset.
"""
import io
import os
import re
import sys

PATH = sys.argv[1] if len(sys.argv) > 1 else sys.exit(__doc__)


def env(name, default=""):
    return os.environ.get(name, default)


def flag(name):
    return env(name, "0") == "1"


COMPATIBLE = env("PANEL_DT_COMPATIBLE")
if not COMPATIBLE:
    sys.exit("PANEL_DT_COMPATIBLE is required")

RESET = int(env("RESET_GPIO_LINE", "1"))
IOVCC = int(env("IOVCC_GPIO_LINE", "4"))
AVDD = int(env("AVDD_GPIO_LINE", "0"))

with io.open(PATH, encoding="utf-8") as fh:
    t = fh.read()

# The phandle of the panel's GPIO controller, taken from the template rather
# than assumed - it is whatever Arduino's overlay used for the reset line.
m = re.search(r"dsi_panel@0 \{.*?reset-gpio = <(0x[0-9a-f]+) ", t, re.S)
if not m:
    sys.exit("could not find the panel node's reset-gpio")
MCU = m.group(1)

# ------------------------------------------------------------- panel node ---
m = re.search(r"(dsi_panel@0 \{.*?)(\n\t+port \{)", t, re.S)
if not m:
    sys.exit("dsi_panel@0 not found")

panel = ('dsi_panel@0 {\n'
         '\t\t\t\treg = <0x00>;\n'
         '\t\t\t\tcompatible = "%s";\n'
         '\t\t\t\treset-gpio = <%s 0x%02x 0x00>;\n'
         '\t\t\t\tiovcc-gpio = <%s 0x%02x 0x00>;\n'
         '\t\t\t\tavdd-gpio = <%s 0x%02x 0x00>;\n'
         '\t\t\t\tbacklight = <%s>;\n'
         % (COMPATIBLE, MCU, RESET, MCU, IOVCC, MCU, AVDD, MCU))
t = t[:m.start(1)] + panel + t[m.end(1):]
print("  panel: %s" % COMPATIBLE)
print("  gpios: reset=%d iovcc=%d avdd=%d, all active-high" % (RESET, IOVCC, AVDD))

# --------------------------------------------------------- the regulators ---
for reg in ("regulator-panel-avdd", "regulator-panel-iovcc"):
    m = re.search(r"\n\t+" + reg + r" \{.*?\n\t+\};", t, re.S)
    if m:
        t = t[:m.start()] + t[m.end():]
        print("  removed %s (the driver drives that line itself)" % reg)

# The vcc rail stays and stays on: a different line, nothing else claims it,
# and the panel wants it up whenever it is powered at all.
m = re.search(r"regulator-panel-vcc \{[^}]*?(?=\n\t+\};)", t, re.S)
if m and "regulator-always-on" not in m.group(0):
    t = t[:m.end()] + "\n\t\t\t\tregulator-always-on;" + t[m.end():]
    print("  panel-vcc kept always-on")

# --------------------------------------------------------------- the touch --
props = []
if flag("TOUCH_SWAP_XY"):
    props.append("touchscreen-swapped-x-y")
if flag("TOUCH_INVERT_X"):
    props.append("touchscreen-inverted-x")
if flag("TOUCH_INVERT_Y"):
    props.append("touchscreen-inverted-y")
if props:
    m = re.search(r"(goodix@5d \{)", t)
    if not m:
        sys.exit("goodix@5d node not found")
    add = "".join("\n\t\t\t\t%s;" % p for p in props)
    t = t[:m.end(1)] + add + t[m.end(1):]
    print("  touch: %s" % ", ".join(props))

# ------------------------------------------------------------- the fixups ---
# __local_fixups__ must name exactly the properties that carry phandles. Left
# naming the deleted supplies, the offline merge fails - silently, resetting
# the display option to "none", which is a long way from the cause.
m = re.search(r"dsi_panel@0 \{\n(?:\t+[a-z-]+ = <0x00>;\n)+\t+\};", t)
if not m:
    sys.exit("dsi_panel fixup block not found")
t = (t[:m.start()] +
     'dsi_panel@0 {\n'
     '\t\t\t\t\treset-gpio = <0x00>;\n'
     '\t\t\t\t\tiovcc-gpio = <0x00>;\n'
     '\t\t\t\t\tavdd-gpio = <0x00>;\n'
     '\t\t\t\t\tbacklight = <0x00>;\n'
     '\t\t\t\t};' +
     t[m.end():])

for reg in ("regulator-panel-avdd", "regulator-panel-iovcc"):
    t = re.sub(r"\n\t+" + reg + r" \{\n\t+gpios = <0x00>;\n\t+\};", "", t)
print("  fixups rewritten to match")

with io.open(PATH, "w", encoding="utf-8", newline="\n") as fh:
    fh.write(t)

#!/usr/bin/env python3
"""Work out which upstream panel entry an unknown display might be.

    python3 tools/match-upstream.py bench/results/goodix/<panel>.txt
    python3 tools/match-upstream.py --resolution 1024x600
    python3 tools/match-upstream.py --driver /path/to/panel-waveshare-dsi-v2.c ...

WHAT THIS CAN AND CANNOT DO
---------------------------
A DSI panel carries **no EDID**. There is no timing information on it at all -
no porches, no pixel clock, no lane count, no initialisation sequence, no power
sequencing. No amount of probing will ever produce those, on any panel.

What a panel does tell you is its touch controller's **digitizer resolution**,
and on every panel recorded here that equals the panel's own resolution (the
12.3 inch reports it transposed, which is handled below).

That one number is useful because Raspberry Pi's driver already holds the mode,
the lane count and the vendor initialisation sequence for seventeen Waveshare
panels. So the job is not to derive anything - it is to work out WHICH of those
seventeen you are holding. This does that, and says plainly when the answer is
not unique.

WHEN IT IS NOT ENOUGH, AND WHY THAT MATTERS
-------------------------------------------
Resolution is a unique key for five of the seven distinct resolutions upstream.
The other two are traps:

    800x1280   4 entries, 2 or 4 lanes
    720x1280   8 entries, clocks from 65 MHz to 83.3 MHz

Choosing wrong there gives a connected connector, the right mode, the right
driver, a clean dmesg - and a garbled picture. That failure is the reason this
tool refuses to pick for you when more than one entry fits.
"""
import argparse
import importlib.util
import io
import os
import re
import sys
import urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)

DRIVER_URL = ("https://raw.githubusercontent.com/raspberrypi/linux/"
              "rpi-6.12.y/drivers/gpu/drm/panel/panel-waveshare-dsi-v2.c")
CACHE = os.path.join(os.path.expanduser("~"), ".uno-q-dsi-build",
                     "upstream-panel-driver.c")


def load_checker():
    """Borrow the dump parser rather than writing a second one."""
    spec = importlib.util.spec_from_file_location(
        "checkfp", os.path.join(HERE, "check-fingerprints.py"))
    m = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(m)
    return m


def get_driver(path=None):
    if path:
        return io.open(path, encoding="utf-8", errors="replace").read()
    if os.path.exists(CACHE):
        return io.open(CACHE, encoding="utf-8", errors="replace").read()
    sys.stderr.write("fetching the upstream driver ...\n")
    try:
        with urllib.request.urlopen(DRIVER_URL, timeout=60) as r:
            text = r.read().decode("utf-8", "replace")
    except Exception as e:
        raise SystemExit(
            "could not fetch %s (%s).\nPass --driver with a local copy."
            % (DRIVER_URL, e))
    try:
        os.makedirs(os.path.dirname(CACHE), exist_ok=True)
        io.open(CACHE, "w", encoding="utf-8").write(text)
    except IOError:
        pass
    return text


def parse_driver(text):
    """Every compatible, with the resolution, lanes and clock it selects."""
    desc = {}
    for m in re.finditer(r"static const struct ws_panel_desc (\w+)\s*=\s*\{"
                         r"(.*?)\n\};", text, re.S):
        body = m.group(2)
        mo = re.search(r"\.mode\s*=\s*&?(\w+)", body)
        ln = re.search(r"\.lanes\s*=\s*(\d+)", body)
        desc[m.group(1)] = (mo.group(1) if mo else None,
                            int(ln.group(1)) if ln else 0)

    modes = {}
    for m in re.finditer(r"static const struct drm_display_mode (\w+)\s*=\s*\{"
                         r"(.*?)\n\};", text, re.S):
        body = m.group(2)
        h = re.search(r"\.hdisplay\s*=\s*(\d+)", body)
        v = re.search(r"\.vdisplay\s*=\s*(\d+)", body)
        c = re.search(r"\.clock\s*=\s*(\d+)", body)
        if h and v:
            modes[m.group(1)] = (int(h.group(1)), int(v.group(1)),
                                 int(c.group(1)) if c else 0)

    out = []
    for m in re.finditer(r'\{\s*\.compatible\s*=\s*"(waveshare,[^"]+)"\s*,'
                         r'\s*&(\w+)\s*\}', text, re.S):
        mo, lanes = desc.get(m.group(2), (None, 0))
        if mo not in modes:
            continue
        h, v, clock = modes[mo]
        out.append({"compatible": m.group(1), "w": h, "h": v,
                    "lanes": lanes, "clock": clock})
    return out


def digitizer_resolution(dump):
    """Touch resolution from a Goodix config block: 0x8048, little-endian."""
    ctrl = dump["ctrl"].get(0x5D)
    if not ctrl:
        return None
    regs = ctrl["regs"]
    if not all(0x8048 + i in regs for i in range(4)):
        return None
    x = regs[0x8048] | (regs[0x8049] << 8)
    y = regs[0x804A] | (regs[0x804B] << 8)
    return x, y


def ours_by_compatible(compat):
    """Is this entry covered here, and how?

    Two ways it can be. A derived panel installs the upstream driver and names
    the entry in PANEL_DT_COMPATIBLE. A stock panel is driven by the kernel's
    own driver and names the same hardware in UPSTREAM_COMPATIBLE, which is
    informational - without reading it, a tested 8 inch looks untried because
    its definition never mentions the upstream entry.
    """
    for f in sorted(os.listdir(os.path.join(ROOT, "panels"))):
        if not f.endswith(".panel") or "TEMPLATE" in f:
            continue
        txt = io.open(os.path.join(ROOT, "panels", f),
                      encoding="utf-8").read()
        m = re.search(r'^PANEL_DT_COMPATIBLE="([^"]+)"', txt, re.M)
        if m and m.group(1) == compat:
            return (f[:-6], "driven by this entry")
        m = re.search(r'^UPSTREAM_COMPATIBLE="([^"]+)"', txt, re.M)
        if m and m.group(1) == compat:
            return (f[:-6], "same panel, driven by the kernel")
    return None


def same_resolution_here(x, y):
    """Our own definitions at this resolution, however they are driven.

    The stock panels carry no upstream compatible to match on - the kernel
    already holds their mode - so without this they look absent even when this
    repository drives precisely that hardware.
    """
    out = []
    pdir = os.path.join(ROOT, "panels")
    for f in sorted(os.listdir(pdir)):
        if not f.endswith(".panel") or "TEMPLATE" in f:
            continue
        txt = io.open(os.path.join(pdir, f), encoding="utf-8").read()

        # STOCK_MODE when the file states one; otherwise the resolution in
        # the description, which every definition here carries.
        m = re.search(r'^STOCK_MODE="(\d+)x(\d+)"', txt, re.M)
        if not m:
            desc = re.search(r'^PANEL_DESC="([^"]*)"', txt, re.M)
            m = re.search(r"(\d+)x(\d+)", desc.group(1)) if desc else None
        if not m:
            continue

        w, h = int(m.group(1)), int(m.group(2))
        if (w, h) not in ((x, y), (y, x)):
            continue

        if re.search(r"^DERIVED_PANEL=1", txt, re.M):
            how = "derived"
        elif re.search(r"^STOCK_SUPPORT=1", txt, re.M):
            how = "stock"
        else:
            how = "described"
        out.append((f[:-6], how))
    return out


def main(argv):
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("dump", nargs="?", help="a capture-panel.sh dump")
    ap.add_argument("--resolution", help="skip the dump, e.g. 1024x600")
    ap.add_argument("--driver", help="local copy of the upstream driver")
    ap.add_argument("--list", action="store_true",
                    help="print every upstream entry and stop")
    a = ap.parse_args(argv)

    entries = parse_driver(get_driver(a.driver))
    if not entries:
        raise SystemExit("could not parse any panel entries from the driver")

    if a.list:
        print("%-34s %11s %6s %10s %s"
              % ("compatible", "resolution", "lanes", "clock kHz", "status"))
        tested = 0
        for e in sorted(entries, key=lambda e: e["compatible"]):
            ours = ours_by_compatible(e["compatible"])
            if ours:
                tested += 1
                status = "%s (%s)" % (ours[0], ours[1])
            else:
                status = "UNTESTED here"
            print("%-34s %11s %6d %10d  %s"
                  % (e["compatible"], "%dx%d" % (e["w"], e["h"]),
                     e["lanes"], e["clock"], status))
        print("")
        print("%d entries; %d driven by a definition here, %d untested."
              % (len(entries), tested, len(entries) - tested))
        print("")
        print("UNTESTED means nobody has put that panel on a bench")
        print("here. Its mode and initialisation sequence are upstream")
        print("and would very likely work - but no definition exists,")
        print("because a definition needs a FINGERPRINT, and that comes")
        print("from the touch controller, which this driver says nothing")
        print("about.")
        print("")
        print("If you have one, you are most of the way to a .panel file:")
        print("    sudo tools/capture-panel.sh <your-id>")
        return 0

    if a.resolution:
        m = re.match(r"^(\d+)\s*[xX]\s*(\d+)$", a.resolution.strip())
        if not m:
            raise SystemExit("--resolution wants something like 1024x600")
        res = (int(m.group(1)), int(m.group(2)))
        source = "given on the command line"
    else:
        if not a.dump:
            raise SystemExit("give a dump file, or --resolution")
        chk = load_checker()
        dump = chk.merge_dumps([chk.load_dump(a.dump)])[0]
        res = digitizer_resolution(dump)
        if res is None:
            print("This dump has no Goodix config block at 0x5d, so it carries")
            print("no digitizer resolution - there is nothing here to match on.")
            print("")
            print("The LCD line is like this: its fingerprint reads an ATTINY,")
            print("which reports an identity but not a size. For such a panel")
            print("the resolution has to come from the vendor's own driver or")
            print("datasheet.")
            return 1
        source = "read from the digitizer at 0x8048"

    x, y = res
    print("Digitizer reports %dx%d  (%s)" % (x, y, source))
    print("")

    exact = [e for e in entries if (e["w"], e["h"]) == (x, y)]
    flipped = [e for e in entries if (e["w"], e["h"]) == (y, x)]
    hits = exact + [e for e in flipped if e not in exact]

    if not hits:
        print("NO upstream entry has this resolution.")
        print("")
        print("That is a real answer, not a failure: this driver carries")
        print("seventeen Waveshare panels and yours is not among them. Nothing")
        print("readable on the panel can supply the timings, because DSI")
        print("carries no EDID - so they have to come from the vendor.")
        print("")
        print("Look for Waveshare's own driver or device tree for this model;")
        print("they publish per-panel sources for the Raspberry Pi and others.")
        print("Then describe it - see docs/ADDING-A-PANEL.md.")
        return 1

    if flipped and not exact:
        print("Matched with the axes TRANSPOSED - the digitizer reports the")
        print("long edge first. The 12.3 inch does the same, and needs")
        print("TOUCH_SWAP_XY=1 as a result.")
        print("")

    if len(hits) == 1:
        e = hits[0]
        ours = ours_by_compatible(e["compatible"])
        print("UNIQUE MATCH")
        print("")
        print("    PANEL_DT_COMPATIBLE=\"%s\"" % e["compatible"])
        print("    %d lanes, %.1f MHz" % (e["lanes"], e["clock"] / 1000.0))
        print("")
        if ours:
            print("Already covered here: panels/%s.panel - %s"
                  % (ours[0], ours[1]))
        else:
            print("Not yet in this repository. The derived path should need a")
            print(".panel file and no code:")
            print("    cp panels/TEMPLATE.panel panels/<your-id>.panel")
            print("    sudo ./scripts/16-install-derived-panel.sh panels/<your-id>.panel")
        print("")
        print("Confirm by eye regardless. A wrong mode gives a connected")
        print("connector, a clean dmesg and a garbled picture.")
        return 0

    print("AMBIGUOUS - %d entries share this resolution:" % len(hits))
    print("")
    for e in sorted(hits, key=lambda e: (e["lanes"], e["clock"])):
        ours = ours_by_compatible(e["compatible"])
        print("    %-34s %d lanes  %6.1f MHz%s"
              % (e["compatible"], e["lanes"], e["clock"] / 1000.0,
                 "   <- %s" % ours[0] if ours else ""))
    clocks = sorted({e["clock"] for e in hits})
    lanes = sorted({e["lanes"] for e in hits})
    print("")
    what = []
    if len(clocks) > 1:
        what.append("clocks span %.1f to %.1f MHz"
                    % (min(clocks) / 1000.0, max(clocks) / 1000.0))
    if len(lanes) > 1:
        what.append("lane counts differ (%s)"
                    % " and ".join(str(l) for l in lanes))
    if what:
        print("Here %s - and none of that is readable from the"
              % " and ".join(what))
        print("panel. The digitizer cannot separate these.")
    else:
        print("These differ only in things the panel does not report.")
    print("")

    # Stock panels carry no PANEL_DT_COMPATIBLE, so they never appear in the
    # list above even when this repository drives exactly this hardware.
    also = same_resolution_here(x, y)
    if also:
        print("This repository already drives a panel of this resolution:")
        for name, how in also:
            print("    panels/%s.panel   (%s path)" % (name, how))
        print("")
    print("Go by what the panel is sold as - the size in its model number is")
    print("the thing these entries differ by. If you cannot tell, try one and")
    print("LOOK at the screen: a wrong choice here is a garbled picture with")
    print("nothing wrong in dmesg, which is the failure this repository has")
    print("met most often.")
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))

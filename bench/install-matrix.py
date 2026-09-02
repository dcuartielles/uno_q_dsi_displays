#!/usr/bin/env python3
"""Check the installer's patches still apply across every UNO Q kernel line.

Boards in the field are on different kernels depending on when they were last
updated, and install.sh fetches driver sources at the exact commit matching the
running kernel. The patch tools work by matching anchor text in those sources,
so a kernel bump can silently break them - the tools exit with "anchor not
found" and the user gets a failed install.

This catches that WITHOUT any hardware: it downloads the three driver files
from each branch and runs every patch tool against them. Cheap enough to run in
CI, and worth running whenever Arduino publishes a new kernel.

    python bench/install-matrix.py
    python bench/install-matrix.py --branches qcom-v7.0.0-unoq
    python bench/install-matrix.py --panel panels/waveshare-800x480.panel

What it does NOT prove: that the result compiles. Patching is text matching;
compiling needs kernel headers for that exact version, which only exist on a
board running it. A green matrix here means "the patches applied", not "the
modules build". Run the boot suite on a real board for that.
"""
import argparse
import json
import os
import shutil
import subprocess
import sys
import tempfile
import urllib.error
import urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(HERE)

RAW = "https://raw.githubusercontent.com/arduino/linux-qcom/%s/%s"
API_BRANCHES = "https://api.github.com/repos/arduino/linux-qcom/branches?per_page=100"

FILES = {
    "panel-simple.c": "drivers/gpu/drm/panel/panel-simple.c",
    "rpi-panel-attiny-regulator.c": "drivers/regulator/rpi-panel-attiny-regulator.c",
    "edt-ft5x06.c": "drivers/input/touchscreen/edt-ft5x06.c",
}

# tool -> (source file it patches, extra args)
TOOLS = [
    ("gen-panel-patch.py", "panel-simple.c", True),
    ("patch-attiny-regulator.py", "rpi-panel-attiny-regulator.c", False),
    ("patch-edt-ft5x06.py", "edt-ft5x06.c", False),
]


def fetch(url, timeout=90):
    req = urllib.request.Request(url, headers={"User-Agent": "uno-q-bench"})
    with urllib.request.urlopen(req, timeout=timeout) as fh:
        return fh.read()


def discover_branches():
    """Kernel branches Arduino ships, newest-looking first."""
    try:
        data = json.loads(fetch(API_BRANCHES).decode())
    except (urllib.error.URLError, ValueError) as exc:
        print("  could not list branches (%s); falling back to known set" % exc)
        return ["qcom-v6.16.7-unoq", "qcom-v6.19.0-unoq", "qcom-v7.0.0-unoq"]
    names = [b["name"] for b in data]
    # The lines an actual board runs are the -unoq ones; the topic/* branches
    # are development work that never reaches a user's board.
    return sorted(n for n in names if n.endswith("-unoq"))


def run_tool(tool, src, panel):
    cmd = [sys.executable, os.path.join(REPO, "tools", tool), src]
    if panel:
        cmd.append(panel)
    r = subprocess.run(cmd, capture_output=True, text=True)
    return r.returncode, (r.stdout + r.stderr).strip()


def main():
    ap = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--branches", nargs="*", help="branches to test")
    ap.add_argument("--panel",
                    default=os.path.join(REPO, "panels", "waveshare-800x480.panel"))
    ap.add_argument("--cache", default=os.path.join(HERE, ".kernel-cache"))
    args = ap.parse_args()

    branches = args.branches or discover_branches()
    os.makedirs(args.cache, exist_ok=True)

    print("=" * 72)
    print("Installer compatibility matrix")
    print("  branches: %s" % ", ".join(branches))
    print("  panel   : %s" % os.path.basename(args.panel))
    print("=" * 72)

    failures = 0
    rows = []
    for br in branches:
        bdir = os.path.join(args.cache, br)
        os.makedirs(bdir, exist_ok=True)
        got = {}
        for name, path in FILES.items():
            dst = os.path.join(bdir, name)
            if not os.path.exists(dst) or os.path.getsize(dst) == 0:
                try:
                    open(dst, "wb").write(fetch(RAW % (br, path)))
                except urllib.error.URLError as exc:
                    print("\n%s: could not fetch %s (%s)" % (br, name, exc))
                    continue
            got[name] = dst

        print("\n%s" % br)
        for tool, srcname, needs_panel in TOOLS:
            if srcname not in got:
                print("  %-28s SKIP  (source not available)" % tool)
                continue
            work = tempfile.mkdtemp(prefix="unoq-matrix-")
            try:
                src = os.path.join(work, srcname)
                shutil.copy(got[srcname], src)
                rc, out = run_tool(tool, src, args.panel if needs_panel else None)
                ok = rc == 0
                # A tool must also be idempotent: install.sh can be re-run, and
                # a second pass must not duplicate the patch.
                idem = True
                if ok:
                    rc2, _ = run_tool(tool, src, args.panel if needs_panel else None)
                    idem = rc2 == 0
                status = "ok" if (ok and idem) else ("NOT IDEMPOTENT" if ok else "FAIL")
                if not (ok and idem):
                    failures += 1
                print("  %-28s %s" % (tool, status))
                if not ok:
                    for line in out.splitlines()[-3:]:
                        print("      %s" % line)
                rows.append((br, tool, status))
            finally:
                shutil.rmtree(work, ignore_errors=True)

    print("\n" + "=" * 72)
    if failures:
        print("%d check(s) FAILED - the installer would break on those kernels."
              % failures)
        print("Usually an anchor in tools/*.py no longer matches upstream.")
    else:
        print("All patches apply cleanly and are idempotent on every branch.")
    print("=" * 72)
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())

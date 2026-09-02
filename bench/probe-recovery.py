#!/usr/bin/env python3
"""Find out what actually rescues a dark panel, by measuring instead of guessing.

Run this ON a boot where the panel came up dark. It applies candidate recovery
actions one at a time and checks the panel with the camera after each, so the
answer is observed rather than reasoned about.

    python bench/probe-recovery.py --camera 1

Why this exists
---------------
On a cold boot the attiny's enable writes fail (PC_LED_EN among them) and the
panel stays dark while every software check reports the display healthy. The
recovery service currently only reloads the touch driver and logs "display is
up", because the DRM connector really is up - it just is not visible.

An obvious guess is "re-write the backlight brightness". That may well be
wrong: in the Raspberry Pi driver, attiny_update_status() writes REG_PWM only,
while PC_LED_EN is asserted in the regulator enable path - so brightness alone
may not re-assert it. Rather than reason further about hardware whose registers
do not even read back, this tries each candidate and looks.

Whatever comes back green here is what belongs in
scripts/35-install-recovery.sh.
"""
import argparse
import json
import os
import shutil
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
SH = shutil.which("sh") or "sh"

# Ordered least to most invasive: prefer the gentlest thing that works.
CANDIDATES = [
    ("write brightness",
     "for b in /sys/class/backlight/*/brightness; do echo 255 > $b; done"),

    ("bl_power off/on",
     "for d in /sys/class/backlight/*/; do echo 1 > $d/bl_power; sleep 1; "
     "echo 0 > $d/bl_power; echo 255 > $d/brightness; done"),

    ("fb0 blank/unblank",
     "echo 1 > /sys/class/graphics/fb0/blank 2>/dev/null; sleep 1; "
     "echo 0 > /sys/class/graphics/fb0/blank 2>/dev/null; true"),

    ("VT switch (forces a modeset)",
     "cur=$(fgconsole 2>/dev/null || echo 7); chvt 3; sleep 2; chvt $cur; true"),

    # The heavy one: re-runs attiny_lcd_power_enable() in full, which is where
    # PC_LED_EN is actually asserted. Last because unbinding a regulator that
    # panel-simple holds as a supply is the most disruptive thing here.
    ("rebind the attiny regulator",
     "d=$(ls /sys/bus/i2c/drivers/rpi_touchscreen_attiny/ | grep -- '-0045' "
     "| head -1); "
     "echo $d > /sys/bus/i2c/drivers/rpi_touchscreen_attiny/unbind 2>/dev/null; "
     "sleep 2; "
     "echo $d > /sys/bus/i2c/drivers/rpi_touchscreen_attiny/bind 2>/dev/null; "
     "true"),
]


def remote(cmd, timeout=90):
    r = subprocess.run([SH, os.path.join(HERE, "remote.sh"), cmd],
                       capture_output=True, text=True, timeout=timeout)
    return r.returncode, r.stdout, r.stderr


def look(camera):
    cmd = [sys.executable, os.path.join(HERE, "optical.py"), "check"]
    if camera is not None:
        cmd += ["--camera", str(camera)]
    r = subprocess.run(cmd, capture_output=True, text=True)
    for line in r.stdout.splitlines():
        if line.strip().startswith("{"):
            try:
                return json.loads(line.strip())
            except ValueError:
                pass
    return {"error": (r.stderr or "no output")[:200]}


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--camera", type=int, default=None)
    ap.add_argument("--settle", type=float, default=4.0)
    ap.add_argument("--stop-on-success", action="store_true", default=True)
    args = ap.parse_args()

    print("Baseline - what does the panel look like right now?")
    before = look(args.camera)
    print("  %s" % json.dumps(before))
    if before.get("has_image"):
        print("")
        print("The panel is already showing an image, so there is nothing to")
        print("recover. Run this on a boot that came up dark.")
        return 2

    results = []
    for name, cmd in CANDIDATES:
        print("")
        print("--> %s" % name)
        rc, out, err = remote(cmd)
        time.sleep(args.settle)
        after = look(args.camera)
        worked = bool(after.get("has_image"))
        results.append({"action": name, "worked": worked, "optical": after})
        print("    %s   %s" % ("RECOVERED" if worked else "no change",
                               json.dumps(after)))
        if worked and args.stop_on_success:
            break

    print("")
    print("=" * 68)
    winners = [r["action"] for r in results if r["worked"]]
    if winners:
        print("Recovered by: %s" % winners[0])
        print("That is the action to add to scripts/35-install-recovery.sh.")
    else:
        print("Nothing recovered the panel from userspace.")
        print("That is itself important: it would mean the dark panel cannot be")
        print("fixed after the fact, and the enable path has to succeed at boot")
        print("- so the fix belongs in the driver's retry logic, not in a")
        print("post-boot service.")
    print("=" * 68)

    out_path = os.path.join(HERE, "recovery-probe.json")
    with open(out_path, "w") as fh:
        json.dump({"before": before, "results": results}, fh, indent=2)
    print("saved %s" % out_path)
    return 0 if winners else 1


if __name__ == "__main__":
    sys.exit(main())

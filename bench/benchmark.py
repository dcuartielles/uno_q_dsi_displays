#!/usr/bin/env python3
"""Reliability benchmark for the UNO Q DSI panel.

The question this answers is "how often does it actually work, and what
correlates with the times it does not" - not "does it work on my desk right
now".

Two suites
----------
boot     Install once, then cold-boot N times and score each boot. This is the
         one that matters: the failure we chase is a flaky CCI I2C bus during
         the first ~90 seconds of boot, and it is intermittent between boots of
         the SAME image. About 2-3 minutes per iteration.

install  Re-run install.sh from scratch each iteration, then boot and score.
         Much slower (~7 min/iteration) but also exercises the fetch, patch and
         build path, which is what varies across kernel lines.

Why COLD boots
--------------
A warm 'reboot' is not a valid test. The panel controller is a separate MCU
that keeps its port state across a warm reboot, so the panel stays lit even
when every I2C write failed - we measured a boot with 565 CCI timeouts where
every single attiny write failed and the display still showed a picture. Only
cutting power actually re-exercises the enable path.

The panel also cannot be blanked from software (brightness=0 and bl_power=1
both merely dim it), so there is no software shortcut for this. Power must
really be cut.

Scoring
-------
Each iteration produces one JSON record combining:
  * software state from the board  (bench/board/collect.sh)
  * optical ground truth from a webcam (optical.py) - because software cannot
    tell a lit panel from a dark one
A boot passes only if BOTH agree: the pipeline is up AND the camera sees a real
image on the panel.

Usage
-----
    python bench/benchmark.py boot --iterations 30
    python bench/benchmark.py boot --iterations 100 --power-off-cmd ... --power-on-cmd ...
    python bench/analyze.py bench/results/<run-id>
"""
import argparse
import datetime
import json
import os
import shutil
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(HERE)
RESULTS = os.path.join(HERE, "results")
SH = shutil.which("sh") or "sh"


# ------------------------------------------------------------------ util ---
def load_conf():
    conf = {}
    path = os.path.join(HERE, "bench.conf")
    if os.path.exists(path):
        for line in open(path):
            line = line.strip()
            if line and not line.startswith("#") and "=" in line:
                k, v = line.split("=", 1)
                conf[k.strip()] = v.strip()
    for k in ("UNOQ_HOST", "UNOQ_USER", "UNOQ_SSH_KEY", "UNOQ_SUDO_PASS"):
        if os.environ.get(k):
            conf[k] = os.environ[k]
    return conf


def remote(cmd, timeout=120):
    """Run a command on the board. Returns (rc, stdout, stderr)."""
    r = subprocess.run([SH, os.path.join(HERE, "remote.sh"), cmd],
                       capture_output=True, text=True, timeout=timeout)
    return r.returncode, r.stdout, r.stderr


def board_is_up(timeout=8):
    try:
        rc, out, _ = remote("echo up", timeout=timeout)
        return rc == 0 and "up" in out
    except subprocess.TimeoutExpired:
        return False
    except Exception:
        return False


def wait_for_board(deadline_s, poll=5.0):
    """Wait until the board answers SSH. Returns seconds waited, or None."""
    start = time.time()
    while time.time() - start < deadline_s:
        if board_is_up():
            return time.time() - start
        time.sleep(poll)
    return None


def optical_check(camera, expect="image", save=None):
    cmd = [sys.executable, os.path.join(HERE, "optical.py"), "check",
           "--expect", expect]
    if camera is not None:
        cmd += ["--camera", str(camera)]
    if save:
        cmd += ["--save", save]
    r = subprocess.run(cmd, capture_output=True, text=True)
    for line in r.stdout.splitlines():
        line = line.strip()
        if line.startswith("{"):
            try:
                return json.loads(line)
            except ValueError:
                pass
    return {"error": (r.stderr or r.stdout or "no output").strip()[:300]}


# ----------------------------------------------------------------- power ---
class Power:
    """Cut and restore power to the board.

    Manual is the default because it needs no extra hardware. If you have a
    smart plug or a switchable USB hub, pass --power-off-cmd/--power-on-cmd and
    the whole run goes unattended - that is what makes N=100 practical.
    """

    def __init__(self, off_cmd=None, on_cmd=None, off_seconds=8):
        self.off_cmd, self.on_cmd = off_cmd, on_cmd
        self.off_seconds = off_seconds
        self.manual = not (off_cmd and on_cmd)

    def cycle(self, i, total):
        if self.manual:
            print("\n  [%d/%d] UNPLUG the board's power now." % (i, total))
            input("        Press Enter once it is unplugged... ")
            time.sleep(2)
            print("        PLUG it back in.")
            input("        Press Enter once it is plugged in... ")
        else:
            subprocess.run([SH, "-c", self.off_cmd])
            time.sleep(self.off_seconds)
            subprocess.run([SH, "-c", self.on_cmd])


# ------------------------------------------------------------ iterations ---
def score(sw, opt):
    """Combine software state and optical truth into a verdict.

    Both have to agree. Software alone cannot see a dark panel; the camera
    alone cannot tell you the touchscreen bound.
    """
    if sw is None:
        return "no_boot", "the board never came back on the network"
    if opt.get("error"):
        return "optical_error", opt["error"]

    display_sw = bool(sw.get("connector")) and sw.get("fb0") == 1
    display_opt = bool(opt.get("has_image"))

    if not display_sw and not display_opt:
        return "fail_display", "no pipeline and nothing on the panel"
    if display_sw and not display_opt:
        # The interesting one: everything looks healthy in software and the
        # screen is blank or dark. Exactly the failure that took longest to
        # find by hand.
        return "fail_dark_panel", "pipeline is up but the panel shows %s" % (
            "nothing" if opt.get("state") == "lit" else opt.get("state"))
    if not display_sw and display_opt:
        return "fail_inconsistent", "panel shows an image but software disagrees"
    if not sw.get("touch_present") and sw.get("touch_expected", True):
        return "fail_touch", "display fine, touchscreen missing"
    return "pass", ""


def run_iteration(i, total, args, power, outdir):
    rec = {"iteration": i,
           "started": datetime.datetime.now().isoformat(timespec="seconds")}

    power.cycle(i, total)
    t0 = time.time()

    waited = wait_for_board(args.boot_timeout)
    rec["ssh_wait_s"] = round(waited, 1) if waited is not None else None
    if waited is None:
        rec["verdict"], rec["note"] = "no_boot", "no SSH within %ds" % args.boot_timeout
        rec["software"], rec["optical"] = None, {}
        return rec

    # Let the recovery service finish before judging: it deliberately waits for
    # the boot-time I2C storm to pass, so measuring earlier would score boots
    # as failures that the system was about to fix by itself.
    time.sleep(args.settle)

    rc, out, err = remote("/home/arduino/bench/collect.sh", timeout=90)
    sw = None
    if rc == 0:
        try:
            sw = json.loads(out[out.index("{"):out.rindex("}") + 1])
        except (ValueError, IndexError):
            rec["collect_error"] = (out or err)[:300]
    else:
        rec["collect_error"] = (err or out)[:300]

    if sw is not None:
        sw["touch_expected"] = not args.no_touch

    shot = os.path.join(outdir, "iter-%03d.png" % i)
    opt = optical_check(args.camera, expect="image", save=shot)

    rec["software"] = sw
    rec["optical"] = opt
    rec["total_s"] = round(time.time() - t0, 1)
    rec["verdict"], rec["note"] = score(sw, opt)

    # Only keep frames from failures - 100 passing screenshots is just clutter.
    if rec["verdict"] == "pass" and os.path.exists(shot) and not args.keep_frames:
        os.remove(shot)
        rec["optical"].pop("frame", None)
    return rec


def colour_sweep(args):
    """Verify the panel renders correct colours, not just 'something'.

    Runs once per run rather than per iteration: it needs VT switching, which
    disturbs the desktop, and it answers a different question - is the DSI data
    path correct - from the boot-reliability one.
    """
    results = {}
    for c in ("red", "green", "blue"):
        remote("/home/arduino/bench/panel-pattern.sh %s 255" % c, timeout=60)
        time.sleep(3)
        r = optical_check(args.camera, expect="colour")
        # expect=colour compares against --colour, which optical.py defaults to
        # red; re-evaluate here against the colour we actually painted.
        results[c] = {"seen": r.get("dominant_colour"),
                      "ok": r.get("dominant_colour") == c,
                      "contrast": r.get("contrast")}
    remote("/home/arduino/bench/panel-pattern.sh restore", timeout=60)
    time.sleep(3)
    return results


# ------------------------------------------------------------------ main ---
def cmd_boot(args):
    conf = load_conf()
    if not conf.get("UNOQ_HOST"):
        sys.exit("no UNOQ_HOST - create bench/bench.conf (see bench/remote.sh)")
    if not os.path.exists(os.path.join(HERE, "optical-cal.json")):
        sys.exit("no optical calibration - run:\n"
                 "    python bench/optical.py calibrate --camera <n>")

    run_id = args.label or datetime.datetime.now().strftime("%Y%m%d-%H%M%S")
    outdir = os.path.join(RESULTS, run_id)
    os.makedirs(outdir, exist_ok=True)

    power = Power(args.power_off_cmd, args.power_on_cmd, args.power_off_seconds)

    print("=" * 68)
    print("UNO Q panel boot-reliability benchmark")
    print("  iterations : %d" % args.iterations)
    print("  power      : %s" % ("MANUAL - you will be prompted each cycle"
                                 if power.manual else "automatic"))
    print("  results    : %s" % outdir)
    print("=" * 68)
    if power.manual:
        print("\nManual power cycling means this needs you at the desk. With a")
        print("smart plug you can pass --power-off-cmd/--power-on-cmd and walk")
        print("away; that is what makes 100 iterations practical.\n")

    meta = {"run_id": run_id, "suite": "boot", "iterations": args.iterations,
            "started": datetime.datetime.now().isoformat(timespec="seconds"),
            "host": conf.get("UNOQ_HOST"), "manual_power": power.manual,
            "notes": args.notes}
    if board_is_up():
        rc, out, _ = remote("/home/arduino/bench/collect.sh")
        try:
            meta["baseline"] = json.loads(out[out.index("{"):out.rindex("}") + 1])
        except (ValueError, IndexError):
            pass
        if not args.skip_colour:
            print("Checking the panel renders correct colours...")
            meta["colour_sweep"] = colour_sweep(args)
            for c, r in meta["colour_sweep"].items():
                print("  %-6s -> %-6s %s" % (c, r["seen"], "ok" if r["ok"] else "MISMATCH"))
    with open(os.path.join(outdir, "run.json"), "w") as fh:
        json.dump(meta, fh, indent=2)

    records = []
    try:
        for i in range(1, args.iterations + 1):
            rec = run_iteration(i, args.iterations, args, power, outdir)
            records.append(rec)
            with open(os.path.join(outdir, "iter-%03d.json" % i), "w") as fh:
                json.dump(rec, fh, indent=2)

            sw = rec.get("software") or {}
            print("  [%d/%d] %-18s cci=%-4s attiny_fail=%-3s touch=%-3s %s"
                  % (i, args.iterations, rec["verdict"],
                     sw.get("cci_timeouts", "?"),
                     sw.get("attiny_write_failures", "?"),
                     sw.get("touch_present", "?"),
                     rec.get("note", "")))
    except KeyboardInterrupt:
        print("\ninterrupted - %d iterations recorded" % len(records))

    npass = sum(1 for r in records if r["verdict"] == "pass")
    print("\n%d/%d passed (%.0f%%)"
          % (npass, len(records), 100.0 * npass / max(len(records), 1)))
    print("Full report:  python bench/analyze.py %s" % outdir)
    return 0


def main():
    ap = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)

    p = sub.add_parser("boot", help="cold-boot reliability")
    p.add_argument("--iterations", type=int, default=20)
    p.add_argument("--camera", type=int, default=None)
    p.add_argument("--settle", type=float, default=70.0,
                   help="seconds after SSH before judging; must exceed the "
                        "recovery service's window (default 70)")
    p.add_argument("--boot-timeout", type=float, default=180.0)
    p.add_argument("--power-off-cmd", help="shell command that cuts power")
    p.add_argument("--power-on-cmd", help="shell command that restores power")
    p.add_argument("--power-off-seconds", type=float, default=8.0)
    p.add_argument("--no-touch", action="store_true",
                   help="this panel has no touchscreen; do not score it")
    p.add_argument("--skip-colour", action="store_true")
    p.add_argument("--keep-frames", action="store_true",
                   help="keep camera frames from passing boots too")
    p.add_argument("--label", help="name for this run (default: timestamp)")
    p.add_argument("--notes", default="", help="free text stored in run.json, "
                                               "e.g. 'PSU B, 3A, cable 2'")
    p.set_defaults(func=cmd_boot)

    args = ap.parse_args()
    sys.exit(args.func(args))


if __name__ == "__main__":
    main()

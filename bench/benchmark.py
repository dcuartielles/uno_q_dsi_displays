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


LOGFILE = None


def log(msg):
    """Timestamped phase log to stdout and a file.

    Added after a run stalled and there was no way to tell which wait it was
    sitting in: the harness printed almost nothing, so diagnosing it meant
    guessing from process state. Every phase transition is now recorded.
    """
    line = "%s  %s" % (time.strftime("%H:%M:%S"), msg)
    print(line, flush=True)
    if LOGFILE:
        try:
            with open(LOGFILE, "a") as fh:
                fh.write(line + chr(10))
        except OSError:
            pass


def _kill_tree(pid):
    """Kill a process and everything it spawned."""
    if sys.platform == "win32":
        subprocess.run(["taskkill", "/F", "/T", "/PID", str(pid)],
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    else:
        try:
            os.killpg(os.getpgid(pid), 9)
        except OSError:
            pass


def remote(cmd, timeout=120):
    """Run a command on the board. Returns (rc, stdout, stderr).

    Deliberately writes output to temporary FILES rather than pipes, and kills
    the whole process tree on timeout.

    subprocess.run(capture_output=True, timeout=...) is unsafe here and cost
    three separate stalled benchmark runs before I understood why. On timeout
    it kills the direct child - sh - but the grandchild ssh survives holding
    the stdout pipe, and communicate() then blocks forever waiting for an EOF
    that can never arrive. The symptom is maddening: the process is alive, has
    no children (sh is dead, the orphaned ssh has been reparented) and makes no
    progress at all.

    Files cannot block on EOF, and killing the tree takes the orphaned ssh with
    it, so neither half of that failure can happen again.
    """
    import tempfile
    with tempfile.TemporaryFile() as out, tempfile.TemporaryFile() as err:
        p = subprocess.Popen([SH, os.path.join(HERE, "remote.sh"), cmd],
                             stdout=out, stderr=err, stdin=subprocess.DEVNULL)
        try:
            rc = p.wait(timeout=timeout)
        except subprocess.TimeoutExpired:
            _kill_tree(p.pid)
            try:
                p.wait(timeout=10)
            except subprocess.TimeoutExpired:
                pass
            rc = -1
        out.seek(0)
        err.seek(0)
        return (rc,
                out.read().decode("utf-8", "replace"),
                err.read().decode("utf-8", "replace"))


def board_is_up(timeout=20):
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


def get_boot_id():
    """The kernel's random boot_id, which changes on every boot."""
    try:
        rc, out, _ = remote("cat /proc/sys/kernel/random/boot_id", timeout=20)
        if rc == 0 and out.strip():
            return out.strip().splitlines()[-1].strip()
    except Exception:
        pass
    return None


def wait_for_new_boot(prev_boot_id, cap=3600.0, poll=5.0,
                      resignal=None, resignal_every=60.0):
    """Wait until the board reports a DIFFERENT boot_id.

    This replaces watching for the board to disappear and come back, which was
    fragile for a reason worth recording: the re-signal makes SSH calls, and if
    one fired just as the operator pulled the plug it could block for its full
    timeout. The board then went down AND came back inside that blind window,
    so the down-transition was never observed and the wait never ended.

    Watching a state instead of a transition cannot miss anything. A changed
    boot_id is positive proof that a fresh boot happened, however briefly we
    looked away.
    """
    start = time.time()
    last_signal = time.time()
    while time.time() - start < cap:
        current = get_boot_id()
        if current and current != prev_boot_id:
            return time.time() - start
        if current and resignal and time.time() - last_signal > resignal_every:
            # Still the old boot, so the operator has not cycled yet - remind
            # them. Safe here because we know the board is answering.
            resignal()
            last_signal = time.time()
        time.sleep(poll)
    return None


def wait_for_gone(cap=900.0, poll=3.0, resignal=None, resignal_every=60.0):
    """Wait until the board stops answering, i.e. someone pulled the power.

    Two consecutive failures are required before believing it: a single slow
    SSH round-trip is not the same as a powered-off board, and treating it as
    one silently desynchronises the harness from the operator.

    The signal is also re-asserted periodically. If the board rebooted for any
    reason the LEDs reset to off, and the operator would then be waiting for a
    cue that never comes while this waits for an unplug that never happens -
    which is exactly how the first attempt deadlocked.
    """
    start = time.time()
    last_signal = time.time()
    misses = 0
    while time.time() - start < cap:
        if not board_is_up():
            misses += 1
            if misses >= 2:
                return time.time() - start
        else:
            misses = 0
            if resignal and time.time() - last_signal > resignal_every:
                resignal()
                last_signal = time.time()
        time.sleep(poll)
    return None


def wait_for_recovery(cap=180.0, poll=5.0):
    """Wait until the boot-recovery service has finished before judging.

    The service deliberately sleeps 25s and then retries for up to 150s, so
    measuring on a fixed timer either wastes time on good boots or scores a
    boot as failed that the system was about to fix by itself. Polling the
    unit's state is both faster and more accurate.
    """
    start = time.time()
    while time.time() - start < cap:
        rc, out, _ = remote(
            "systemctl show -p ActiveState --value uno-q-dsi-panel-recover "
            "2>/dev/null || echo missing", timeout=20)
        state = (out or "").strip().splitlines()[-1] if out.strip() else "missing"
        if state in ("active", "failed", "missing"):
            return time.time() - start
        time.sleep(poll)
    return None


def set_leds(colour=None):
    """Blink the Media Carrier LEDs, or clear them when colour is None.

    The carrier has four each of red/green/blue under /sys/class/leds. They are
    the RELIABLE half of the operator signal: the panel signal is invisible in
    exactly the failure we care most about - a boot where the pipeline is up
    but the screen stays dark - and without these the run would stall on its
    most interesting result, waiting for an unplug that never comes.
    """
    if colour is None:
        cmd = ("for d in /sys/class/leds/media-carrier:*/; do "
               "echo none > $d/trigger 2>/dev/null; "
               "echo 0 > $d/brightness 2>/dev/null; done")
    else:
        cmd = ("for d in /sys/class/leds/media-carrier:%s*/; do "
               "echo timer > $d/trigger 2>/dev/null; "
               "echo 400 > $d/delay_on 2>/dev/null; "
               "echo 400 > $d/delay_off 2>/dev/null; done" % colour)
    try:
        remote(cmd, timeout=15)
        return True
    except Exception:
        return False


def signal_operator(colour="green"):
    """Tell the operator the measurement is done and it is safe to unplug.

    Two channels, because either one alone can fail. The operator cannot see
    this script's output - it may be running from another machine - but they
    are looking straight at the board. The panel is the obvious signal; the
    carrier LEDs are the one that still works when the panel is dark.
    """
    leds = set_leds(colour)
    try:
        # Short timeout on purpose. A long one here once blocked for its full
        # duration while the operator pulled the plug, hiding the whole power
        # cycle from the detector.
        rc, _, _ = remote("/home/arduino/bench/panel-pattern.sh %s 255" % colour,
                          timeout=15)
        return rc == 0 or leds
    except Exception:
        return leds


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

    def __init__(self, off_cmd=None, on_cmd=None, off_seconds=8,
                 unplug_timeout=900.0):
        self.off_cmd, self.on_cmd = off_cmd, on_cmd
        self.off_seconds = off_seconds
        self.unplug_timeout = unplug_timeout
        self.manual = not (off_cmd and on_cmd)

    def cycle(self, i, total, detect=True):
        """Cut and restore power. Returns seconds spent waiting for a human."""
        if not self.manual:
            subprocess.run([SH, "-c", self.off_cmd])
            time.sleep(self.off_seconds)
            subprocess.run([SH, "-c", self.on_cmd])
            return 0.0

        if not detect:
            print("\n  [%d/%d] UNPLUG the board, then plug it back in." % (i, total))
            input("        Press Enter once it is plugged back in... ")
            return 0.0

        # Detect mode: no keyboard at all. Tell the operator on the panel that
        # the measurement is finished, then simply watch for the board to drop
        # off the network.
        if board_is_up():
            signal_operator("green")
            log("[%d/%d] SIGNAL GREEN - unplug the board now, then plug it "
                "back in" % (i, total))
        else:
            log("[%d/%d] board is down already; waiting for it to come back"
                % (i, total))
        # The waiting is done by run_iteration, which watches for a new
        # boot_id. Nothing here can miss the power cycle.
        return 0.0


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

    prev_boot = get_boot_id() if not args.prompt else None
    try:
        human_s = power.cycle(i, total, detect=not args.prompt)
    except TimeoutError as exc:
        rec.update({"verdict": "aborted", "note": str(exc),
                    "software": None, "optical": {}})
        return rec
    rec["waited_for_operator_s"] = round(human_s, 1)
    t0 = time.time()

    if prev_boot is not None:
        log("[%d/%d] waiting for a NEW boot (previous boot_id %s)"
            % (i, total, prev_boot[:8]))
        waited = wait_for_new_boot(
            prev_boot, cap=args.unplug_timeout + args.boot_timeout,
            resignal=lambda: signal_operator("green"))
    else:
        log("[%d/%d] waiting for the board to come back up" % (i, total))
        waited = wait_for_board(args.boot_timeout)
    rec["ssh_wait_s"] = round(waited, 1) if waited is not None else None
    if waited is not None:
        log("[%d/%d] board up after %.0fs; measuring (LEDs off)"
            % (i, total, waited))
        set_leds(None)
    if waited is None:
        rec["verdict"], rec["note"] = "no_boot", "no SSH within %ds" % args.boot_timeout
        rec["software"], rec["optical"] = None, {}
        return rec

    # Let the recovery service finish before judging, rather than sleeping a
    # fixed time: it waits out the boot-time I2C storm, so measuring early
    # would score boots as failed that the system was about to fix itself.
    rec["recovery_wait_s"] = wait_for_recovery(args.settle)
    log("[%d/%d] recovery settled after %ss; capturing the panel"
        % (i, total, round(rec["recovery_wait_s"] or -1)))
    time.sleep(args.post_settle)

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
    global LOGFILE
    LOGFILE = os.path.join(outdir, "run.log")

    power = Power(args.power_off_cmd, args.power_on_cmd, args.power_off_seconds,
                  args.unplug_timeout)

    print("=" * 68)
    print("UNO Q panel boot-reliability benchmark")
    print("  iterations : %d" % args.iterations)
    mode = "automatic"
    if power.manual:
        mode = "manual, keyboard prompts" if args.prompt else                "manual, detected (watch the LEDs/panel)"
    print("  power      : %s" % mode)
    print("  results    : %s" % outdir)
    print("=" * 68)
    if power.manual and not args.prompt:
        print("")
        print("MANUAL POWER CYCLING - no keyboard needed. Watch the PANEL:")
        print("  * when it turns SOLID GREEN the measurement is finished:")
        print("    unplug the board, wait a few seconds, plug it back in")
        print("  * then just wait - the next measurement runs by itself")
        print("  * do NOT unplug before it goes green, or that reading is lost")
        print("")
    elif power.manual:
        print("")
        print("Manual power cycling with keyboard prompts.")
        print("")

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

            if rec["verdict"] == "aborted":
                # The operator stopped cycling. Do not spin through the
                # remaining iterations recording the same timeout.
                print("  stopping: %s" % rec.get("note", ""))
                records.pop()
                break

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
    p.add_argument("--settle", type=float, default=200.0,
                   help="max seconds to wait for the recovery service to "
                        "finish before judging (default 200)")
    p.add_argument("--post-settle", type=float, default=8.0,
                   help="extra seconds after recovery finishes")
    p.add_argument("--prompt", action="store_true",
                   help="ask for Enter at each power cycle instead of "
                        "detecting it (needs an interactive terminal)")
    p.add_argument("--unplug-timeout", type=float, default=3600.0,
                   help="how long to wait for the operator to pull the plug "
                        "(default 1 hour - they may not be at the desk)")
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

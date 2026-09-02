#!/usr/bin/env python3
"""Turn a benchmark run into a report.

Beyond the pass rate, this looks for what SEPARATES the failures from the
passes. With an intermittent hardware fault that is the whole point: knowing
you are at 82% is much less useful than knowing the failures all had hundreds
of CCI timeouts and the passes had two.

    python bench/analyze.py bench/results/<run-id> [more-runs...]
"""
import argparse
import glob
import json
import math
import os
import sys

# Numeric fields worth comparing between passing and failing boots.
METRICS = [
    ("cci_timeouts", "CCI I2C timeouts"),
    ("attiny_write_failures", "attiny write failures"),
    ("touch_probe_failures", "touch probe failures"),
    ("backlight_enable_failed", "backlight enable failed"),
    ("dsi_errors", "DSI errors"),
    ("touch_bound_at_s", "touch bound at (s)"),
    ("last_cci_timeout_s", "last CCI timeout (s)"),
    ("recovery_ran", "recovery service ran"),
    ("recovery_succeeded", "recovery succeeded"),
]


def load_run(d):
    meta = {}
    mp = os.path.join(d, "run.json")
    if os.path.exists(mp):
        meta = json.load(open(mp))
    recs = []
    for p in sorted(glob.glob(os.path.join(d, "iter-*.json"))):
        try:
            recs.append(json.load(open(p)))
        except ValueError:
            pass
    return meta, recs


def wilson(k, n, z=1.96):
    """Wilson score interval - honest error bars for a proportion.

    The naive p +/- 1.96*sqrt(p(1-p)/n) is badly wrong near 0% and 100%, which
    is exactly where a reliability benchmark lives. At 20/20 it would claim
    +/-0%; Wilson correctly reports roughly 84-100%.
    """
    if n == 0:
        return 0.0, 0.0
    p = k / n
    d = 1 + z * z / n
    c = (p + z * z / (2 * n)) / d
    h = z * math.sqrt(p * (1 - p) / n + z * z / (4 * n * n)) / d
    return max(0.0, c - h), min(1.0, c + h)


def stats(vals):
    vals = [v for v in vals if isinstance(v, (int, float))]
    if not vals:
        return None
    vals.sort()
    n = len(vals)
    return {"n": n, "min": vals[0], "max": vals[-1],
            "median": vals[n // 2],
            "mean": sum(vals) / n}


def report(dirs):
    all_recs, metas = [], []
    for d in dirs:
        meta, recs = load_run(d)
        meta["_dir"] = d
        metas.append(meta)
        for r in recs:
            r["_run"] = meta.get("run_id", os.path.basename(d))
        all_recs += recs

    if not all_recs:
        sys.exit("no iteration records found in: %s" % ", ".join(dirs))

    n = len(all_recs)
    npass = sum(1 for r in all_recs if r.get("verdict") == "pass")
    lo, hi = wilson(npass, n)

    print("=" * 68)
    print("UNO Q panel benchmark report")
    for m in metas:
        line = "  run %s: %s iterations" % (m.get("run_id", "?"),
                                            m.get("iterations", "?"))
        if m.get("notes"):
            line += "   [%s]" % m["notes"]
        print(line)
    print("=" * 68)

    print("\nSUCCESS RATE")
    print("  %d/%d passed = %.1f%%" % (npass, n, 100.0 * npass / n))
    print("  95%% confidence interval: %.1f%% - %.1f%%" % (100 * lo, 100 * hi))
    if n < 20:
        print("  NOTE: with only %d iterations the interval is very wide." % n)
        print("        Treat this as a smoke test, not a measurement.")

    # ----------------------------------------------------------- verdicts ---
    print("\nOUTCOMES")
    kinds = {}
    for r in all_recs:
        kinds.setdefault(r.get("verdict", "?"), []).append(r)
    explain = {
        "pass": "display and touch both came up",
        "fail_dark_panel": "SOFTWARE LOOKED FINE BUT THE PANEL WAS BLANK/DARK",
        "fail_display": "no display pipeline and nothing on the panel",
        "fail_touch": "display fine, touchscreen missing",
        "no_boot": "the board never came back on the network",
        "fail_inconsistent": "camera and software disagreed",
        "optical_error": "the camera check itself failed",
        "aborted": "the run was stopped waiting for a power cycle",
    }
    for k in sorted(kinds, key=lambda k: -len(kinds[k])):
        v = kinds[k]
        print("  %-20s %3d  (%4.1f%%)  %s"
              % (k, len(v), 100.0 * len(v) / n, explain.get(k, "")))

    # --------------------------------------------- what separates failures ---
    passes = [r for r in all_recs if r.get("verdict") == "pass"]
    fails = [r for r in all_recs if r.get("verdict") != "pass"]

    if passes and fails:
        print("\nWHAT SEPARATES FAILURES FROM PASSES")
        print("  %-26s %-22s %-22s" % ("", "passed", "failed"))
        for key, label in METRICS:
            ps = stats([(r.get("software") or {}).get(key) for r in passes])
            fs = stats([(r.get("software") or {}).get(key) for r in fails])
            if not ps and not fs:
                continue
            fmt = lambda s: ("median %-7.1f (%.0f-%.0f)"
                             % (s["median"], s["min"], s["max"])) if s else "-"
            print("  %-26s %-22s %-22s" % (label, fmt(ps), fmt(fs)))

        # Call out the strongest separator in plain language.
        best, best_ratio = None, 1.0
        for key, label in METRICS:
            ps = stats([(r.get("software") or {}).get(key) for r in passes])
            fs = stats([(r.get("software") or {}).get(key) for r in fails])
            if ps and fs and ps["median"] >= 0:
                ratio = (fs["median"] + 1.0) / (ps["median"] + 1.0)
                if ratio > best_ratio:
                    best, best_ratio = label, ratio
        if best and best_ratio > 2:
            print("\n  Strongest signal: %s, about %.0fx higher on failed boots."
                  % (best, best_ratio))

    # ------------------------------------------------------------- optical ---
    dark = [r for r in all_recs
            if (r.get("optical") or {}).get("state") == "dark"]
    blank = [r for r in all_recs
             if (r.get("optical") or {}).get("state") == "lit"
             and not (r.get("optical") or {}).get("has_image")]
    if dark or blank:
        print("\nWHAT THE CAMERA SAW")
        print("  panel dark                  %3d" % len(dark))
        print("  panel lit but nothing drawn %3d" % len(blank))
        print("  (neither is visible to software - this is why the camera is here)")

    # -------------------------------------------------------------- timing ---
    waits = stats([r.get("ssh_wait_s") for r in all_recs])
    if waits:
        print("\nBOOT TIME TO SSH")
        print("  median %.0fs   range %.0f-%.0fs"
              % (waits["median"], waits["min"], waits["max"]))

    # ------------------------------------------------------------ failures ---
    if fails:
        print("\nFAILED ITERATIONS")
        for r in fails[:20]:
            sw = r.get("software") or {}
            op = r.get("optical") or {}
            print("  #%-3s %-18s cci=%-5s attiny=%-4s panel=%s/%s  %s"
                  % (r.get("iteration"), r.get("verdict"),
                     sw.get("cci_timeouts", "?"),
                     sw.get("attiny_write_failures", "?"),
                     op.get("state", "?"),
                     "image" if op.get("has_image") else "blank",
                     r.get("note", "")))
            if op.get("frame"):
                print("       frame: %s" % op["frame"])
        if len(fails) > 20:
            print("  ... and %d more" % (len(fails) - 20))
    print("")
    return 0


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("dirs", nargs="+", help="one or more bench/results/<run-id>")
    args = ap.parse_args()
    sys.exit(report(args.dirs))


if __name__ == "__main__":
    main()

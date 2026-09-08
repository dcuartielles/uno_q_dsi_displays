#!/usr/bin/env python3
"""Compare two touch-boots runs and say whether the difference is real.

    python bench/touch-analyze.py bench/results/touch/baseline*.log \\
                                  --against bench/results/touch/fixed*.log

Scored on BUG-HIT BOOTS ONLY, which needs saying out loud because it looks
like cherry-picking and is the opposite. On a boot where the I2C bus behaves,
both drivers bind the touchscreen at about 12 s; including those boots does not
make the comparison fairer, it just dilutes it with cases where no difference
is possible. The bug decides which boots it appears on, not us - so the
threshold below is a property of the hardware, not a knob to tune.

The same convention is used for the cold-boot dark-panel figures in
tools/check-docs.py, and for the same reason.
"""
import argparse
import glob
import sys

# A boot either wedges the bus or barely touches it; the measured distribution
# leaves a clear gap in between. Observed counts, sorted:
#
#   0 0 1 2 2 2 2 3 4 16 17 17 17 18 18 19 |
#                    37 38 94 95 110 135 139 144 144 144 145 145 145 146 151 152
#
# Across 32 boots nothing lands between 19 and 37, so any threshold in that gap
# classifies every boot identically - which is what makes drawing one
# defensible rather than a knob that could be tuned until the answer came out
# right.
WEDGE_THRESHOLD = 30


def parse(paths):
    """Read the columns touch-boots.sh prints."""
    rows = []
    for path in paths:
        for line in open(path):
            f = line.split()
            if len(f) < 5 or f[0] == "boot" or not f[0].isdigit():
                continue
            if not (f[1].isdigit() and f[3].isdigit()):
                continue
            rows.append({"timeouts": int(f[1]),
                         "deferred": f[2] not in ("0", "-"),
                         "touch": int(f[3]) > 0,
                         "at": f[4]})
    return rows


def fisher_two_tailed(a, b, c, d):
    """Two-tailed Fisher exact test on [[a, b], [c, d]].

    Sums every table at least as improbable as the observed one, which is the
    convention check-docs.py uses; scipy is not a dependency here.
    """
    from math import comb

    n = a + b + c + d
    row1, col1 = a + b, a + c

    def prob(x):
        return (comb(row1, x) * comb(n - row1, col1 - x) / comb(n, col1))

    lo = max(0, col1 - (n - row1))
    hi = min(row1, col1)
    observed = prob(a)
    # A tiny epsilon keeps floating-point ties from being dropped.
    return sum(prob(x) for x in range(lo, hi + 1)
               if prob(x) <= observed * (1 + 1e-9))


def summarise(name, rows):
    hit = [r for r in rows if r["timeouts"] >= WEDGE_THRESHOLD]
    ok = [r for r in rows if r["timeouts"] < WEDGE_THRESHOLD]
    print("%s  (%d boots)" % (name, len(rows)))
    print("  bug-hit boots : %d, touch present on %d"
          % (len(hit), sum(r["touch"] for r in hit)))
    print("  clean boots   : %d, touch present on %d"
          % (len(ok), sum(r["touch"] for r in ok)))
    if any(r["deferred"] for r in hit):
        print("  deferred      : %d" % sum(r["deferred"] for r in hit))
    return sum(r["touch"] for r in hit), len(hit) - sum(r["touch"] for r in hit)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("baseline", nargs="+")
    ap.add_argument("--against", nargs="+", required=True)
    a = ap.parse_args()

    base_paths = [p for g in a.baseline for p in sorted(glob.glob(g)) or [g]]
    fix_paths = [p for g in a.against for p in sorted(glob.glob(g)) or [g]]

    base, fix = parse(base_paths), parse(fix_paths)
    if not base or not fix:
        sys.exit("no parseable rows - are those touch-boots.sh logs?")

    b_ok, b_bad = summarise("baseline", base)
    print()
    f_ok, f_bad = summarise("with the fix", fix)

    if b_ok + b_bad == 0 or f_ok + f_bad == 0:
        sys.exit("\nno bug-hit boots in one of the runs - nothing to compare. "
                 "Run more boots; roughly one in three hits it.")

    print("\ntouch present on bug-hit boots")
    print("  baseline     : %d/%d" % (b_ok, b_ok + b_bad))
    print("  with the fix : %d/%d" % (f_ok, f_ok + f_bad))
    print("  fisher two-tailed p = %.5f"
          % fisher_two_tailed(b_ok, b_bad, f_ok, f_bad))


if __name__ == "__main__":
    main()

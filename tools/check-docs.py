#!/usr/bin/env python3
"""Verify the documentation still agrees with the measurements.

Why this exists
---------------
The docs in this repository are precise, which makes a stale number more
dangerous than a missing one: a confident, specific, wrong figure gets
believed. It has already happened three times.

  * the README said the panel is "black for ~40 seconds" long after the
    in-driver repair had cut it to about four - understating the fix by an
    order of magnitude and telling users to expect a fault that no longer
    occurred
  * TROUBLESHOOTING said kernel upgrades "wipe this" and to re-run install.sh,
    which stopped being true the moment DKMS was added
  * the "what gets changed" table omitted the DKMS registration, so a user
    consulting it could not know what uninstall.sh would reverse

Each time the measurement changed and the prose did not. Remembering to update
the docs is not a mechanism; this is.

What it does
------------
Recomputes the headline figures from bench/results/, then checks that every
document quoting one quotes the CURRENT value. A figure that has drifted fails
the build with the file, the claim and the correct number.

It deliberately does NOT try to parse arbitrary prose. It checks a small,
explicit table of claims - the numbers we actually repeat across documents -
because a checker nobody trusts gets disabled.

    python tools/check-docs.py            # verify
    python tools/check-docs.py --facts    # print the computed figures
"""
import argparse
import glob
import json
import math
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(HERE)
RESULTS = os.path.join(REPO, "bench", "results")

# Which benchmark runs represent which configuration. Stated explicitly so the
# reader can see what is being compared, rather than inferring it from labels.
BASELINE_RUNS = ("cold20",)          # no fixes at all
FIXED_RUNS = ("cold-combined", "cold-inDriver")   # driver fix in place


def load_records():
    """Every iteration record, tagged with the run directory it came from."""
    out = []
    pattern = os.path.join(RESULTS, "**", "iter-*.json")
    for path in glob.glob(pattern, recursive=True):
        run = os.path.basename(os.path.dirname(path))
        try:
            with open(path) as fh:
                rec = json.load(fh)
        except (ValueError, OSError):
            continue
        rec["_run"] = run
        out.append(rec)
    return out


def _bucket(run):
    for name in FIXED_RUNS:
        if run.startswith(name):
            return "fixed"
    for name in BASELINE_RUNS:
        # startswith, so archived copies like cold20-partial-2116 count too
        if run.startswith(name):
            return "baseline"
    return None


def fisher_two_tailed(a, b, c, d):
    """Two-tailed Fisher exact test on a 2x2 table."""
    def p_of(a, b, c, d):
        return (math.comb(a + b, a) * math.comb(c + d, c) /
                math.comb(a + b + c + d, a + c))
    obs = p_of(a, b, c, d)
    total = 0.0
    for i in range(0, min(a + b, a + c) + 1):
        j, k = a + b - i, a + c - i
        l = c + d - k
        if j < 0 or k < 0 or l < 0:
            continue
        p = p_of(i, j, k, l)
        if p <= obs + 1e-12:
            total += p
    return total


def compute_facts():
    recs = load_records()
    facts = {"n_records": len(recs)}

    groups = {"baseline": [], "fixed": []}
    for r in recs:
        g = _bucket(r["_run"])
        if g:
            groups[g].append(r)

    # Only boots that ACTUALLY HIT THE BUG can show whether a fix works; a
    # clean boot proves nothing either way.
    for name, rs in groups.items():
        bad = [r for r in rs
               if ((r.get("software") or {}).get("attiny_write_failures") or 0) > 0]
        lit = sum(1 for r in bad if r.get("verdict") == "pass")
        facts["%s_bughit_total" % name] = len(bad)
        facts["%s_bughit_lit" % name] = lit
        facts["%s_bughit_dark" % name] = len(bad) - lit

    if facts.get("baseline_bughit_total") and facts.get("fixed_bughit_total"):
        facts["fisher_p"] = fisher_two_tailed(
            facts["baseline_bughit_dark"], facts["baseline_bughit_lit"],
            facts["fixed_bughit_dark"], facts["fixed_bughit_lit"])

    # Touch bind time on boots where it bound on the first probe.
    clean = [(r.get("software") or {}).get("touch_bound_at_s")
             for r in groups["fixed"]
             if (r.get("software") or {}).get("touch_bound_at_s")]
    clean = sorted(v for v in clean if isinstance(v, (int, float)) and v < 30)
    if clean:
        facts["touch_bind_s"] = round(clean[len(clean) // 2])

    # The p-value is quoted as a decimal string, so compare digits rather than
    # floats - "0.00039" and "0.0013" differ in length as well as value.
    if "fisher_p" in facts:
        facts["fisher_p_digits"] = int(("%.5f" % facts["fisher_p"]).split(".")[1])

    return facts


# --------------------------------------------------------------- the claims --
# Each entry: the file, a human name, a regex whose first group is the number
# the document asserts, and the fact it must match.
CLAIMS = [
    ("README.md", "bug-hit boots left dark without the fixes",
     r"without either fix \|\s*\*\*(\d+)\*\*", "baseline_bughit_dark"),
    ("README.md", "bug-hit boots working with the fixes",
     r"with both \(this repo\) \|\s*\*\*(\d+)\*\*\s*\|\s*\*\*(\d+)\*\*",
     ("fixed_bughit_dark", "fixed_bughit_lit")),
    ("README.md", "Fisher p-value (in units of 1e-5)",
     r"Fisher exact two-tailed p = 0\.(\d+)", "fisher_p_digits"),
    ("README.md", "touch bind time",
     r"binds at\s*\n?\s*(\d+)\s*s on the first probe", "touch_bind_s"),
    ("bench/RESULTS.md", "touch bind time",
     r"binds at \*\*(\d+)\s*s on the first probe", "touch_bind_s"),
]

# Figures that were true once and must never reappear as current behaviour.
# Each is a file, a pattern, and why it is wrong now.
STALE = [
    ("README.md", r"black for ~40 seconds",
     "the in-driver repair cut this to about four seconds"),
    ("README.md", r"Kernel upgrades wipe this",
     "DKMS rebuilds the modules on upgrade"),
    ("docs/TROUBLESHOOTING.md", r"\*\*Expected\.\*\* The modules are built against one kernel",
     "DKMS handles kernel upgrades now"),
]


def check(facts, verbose=False):
    problems = []

    for rel, name, pattern, key in CLAIMS:
        path = os.path.join(REPO, rel)
        if not os.path.exists(path):
            problems.append("%s: missing (claim %r)" % (rel, name))
            continue
        text = open(path, encoding="utf-8").read()
        m = re.search(pattern, text)
        if not m:
            problems.append(
                "%s: could not find the %s claim.\n"
                "    Either the wording changed - update CLAIMS in "
                "tools/check-docs.py - or the figure was dropped." % (rel, name))
            continue
        keys = key if isinstance(key, tuple) else (key,)
        for i, k in enumerate(keys):
            want = facts.get(k)
            if want is None:
                continue
            got = int(m.group(i + 1))
            if got != want:
                problems.append(
                    "%s: %s says %d, measurements say %d\n"
                    "    Fix the document, or re-check bench/results/."
                    % (rel, name, got, want))
            elif verbose:
                print("  ok  %-22s %s = %d" % (rel, name, got))

    for rel, pattern, why in STALE:
        path = os.path.join(REPO, rel)
        if not os.path.exists(path):
            continue
        if re.search(pattern, open(path, encoding="utf-8").read()):
            problems.append("%s: contains a superseded claim matching %r\n"
                            "    %s" % (rel, pattern, why))

    return problems


def main():
    ap = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--facts", action="store_true",
                    help="print the computed figures and exit")
    ap.add_argument("-v", "--verbose", action="store_true")
    args = ap.parse_args()

    facts = compute_facts()
    if args.facts:
        print(json.dumps(facts, indent=2, sort_keys=True))
        return 0

    if not facts.get("n_records"):
        print("no benchmark records found under bench/results - skipping")
        return 0

    print("Checking documentation against %d measured boots" % facts["n_records"])
    print("  baseline: %s of %s bug-hit boots left the panel dark"
          % (facts.get("baseline_bughit_dark"), facts.get("baseline_bughit_total")))
    print("  fixed   : %s of %s bug-hit boots left the panel dark"
          % (facts.get("fixed_bughit_dark"), facts.get("fixed_bughit_total")))
    if "fisher_p" in facts:
        print("  fisher p = %.5f" % facts["fisher_p"])
    print("")

    problems = check(facts, verbose=args.verbose)
    if problems:
        print("DOCUMENTATION IS OUT OF DATE:")
        for p in problems:
            print("  - %s" % p)
        print("")
        print("A precise wrong number is worse than no number: people believe it.")
        return 1

    print("documentation agrees with the measurements")
    return 0


if __name__ == "__main__":
    sys.exit(main())

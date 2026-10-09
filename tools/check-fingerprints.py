#!/usr/bin/env python3
"""Replay every recorded panel against every definition. No hardware needed.

    python tools/check-fingerprints.py                 # the CI check
    python tools/check-fingerprints.py --suggest FILE  # propose a fingerprint

WHY THIS EXISTS
---------------
The hard part of adding a panel is not the driver. It is proving the
fingerprint picks out one panel and only one - and that has gone wrong three
times here, every time caught by hand and late:

  * the Waveshare 7.0inch C reports Goodix product ID 911, the same as the
    Arduino 5 inch, and was detected as one with complete confidence
  * the Waveshare 8.8inch shares the product ID with the 8, 10.1 and 12.3 inch
    AND the thresholds with the 10.1 inch, so it was detected as a 10.1 inch
  * the 8 inch and 10.1 inch are byte-identical except for two threshold bytes,
    and nothing else can separate them at all

Each of those was a review that a person had to do, against panels they
happened to remember. This does it exhaustively, in a second, against every
panel anyone has ever recorded.

HOW
---
Every panel contributed here ships a dump of its touch controller's config
block (bench/results/goodix/). That dump is a record of what the real hardware
answers. A detection definition is a short script of reads against the same
controller - so the dump is enough to answer "what would THIS definition see if
THAT panel were plugged in?" without the panel being plugged in.

Replay all definitions against all dumps and the invariant is simple: each
recorded panel must be matched by exactly one definition, and it must be its
own. Anything else is a collision, and it fails the build.

The limit worth knowing: a dump only covers the registers it recorded, on one
address. A definition that reads somewhere else cannot be judged, and is
reported as unverifiable rather than quietly passed.
"""
import argparse
import glob
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)

# The Qualcomm CCI controller on this carrier refuses any read longer than
# this. A definition that asks for more cannot work on the hardware it is
# written for, and the failure at runtime is an unhelpful -EOPNOTSUPP.
CCI_MAX_READ = 12

# Where the product ID lives on a Goodix controller, and where a dump records
# it separately from the config block.
PRODUCT_ID_REG = 0x8140


# ------------------------------------------------------------------ dumps ---

def load_dump(path):
    """Parse a goodix-config.sh dump into something probeable."""
    d = {"path": path, "name": os.path.splitext(os.path.basename(path))[0],
         "addr": None, "id": [], "regs": {}}
    with open(path) as fh:
        for line in fh:
            line = line.strip()
            if line.startswith("#"):
                m = re.search(r"addr=(0x[0-9a-fA-F]+)", line)
                if m:
                    d["addr"] = int(m.group(1), 16)
                m = re.search(r"id=(.+)$", line)
                if m:
                    d["id"] = [int(b, 16) for b in m.group(1).split()]
                continue
            m = re.match(r"^([0-9a-fA-F]{4}):\s*(.+)$", line)
            if not m:
                continue
            base = int(m.group(1), 16)
            for i, b in enumerate(m.group(2).split()):
                d["regs"][base + i] = int(b, 16)
    return d


def read_dump(dump, addr, write, nbytes):
    """What this dump would answer. None when the dump cannot say.

    Being explicit about "cannot say" is the point: a definition probing an
    address or a register nobody recorded must not be scored as a pass.
    """
    if addr is not None and dump["addr"] is not None and addr != dump["addr"]:
        return None
    if not write:
        return None                      # a plain read, not recorded
    if len(write) != 2:
        return None                      # not a 16-bit register address
    reg = (write[0] << 8) | write[1]

    if reg == PRODUCT_ID_REG:
        if not dump["id"]:
            return None
        return dump["id"][:nbytes]

    out = []
    for i in range(nbytes):
        if reg + i not in dump["regs"]:
            return None
        out.append(dump["regs"][reg + i])
    return out


# ----------------------------------------------------------------- panels ---

def parse_bytes(s):
    return [int(b, 16) for b in s.split()] if s else []


def load_panel(path):
    """Pull the fields out of a .panel file. It is shell, but only just."""
    p = {"path": path, "id": os.path.splitext(os.path.basename(path))[0]}
    with open(path) as fh:
        for line in fh:
            line = line.strip()
            m = re.match(r'^([A-Z0-9_]+)="?([^"#]*)"?', line)
            if m:
                p[m.group(1)] = m.group(2).strip()
    return p


def stages(panel):
    """The probe chain: stage 1, then any DETECT2_/DETECT3_/DETECT4_."""
    out = []
    for n in ("", "2", "3", "4"):
        want = panel.get("DETECT%s_EXPECT" % n)
        if not want:
            continue
        out.append({
            "n": n or "1",
            "addr": panel.get("DETECT%s_ADDR" % n) or panel.get("DETECT_ADDR"),
            "write": panel.get("DETECT%s_WRITE" % n),
            "read": int(panel.get("DETECT%s_READ" % n) or 1),
            "expect": want,
        })
    return out


def expect_matches(got, expect):
    """detect-panel.sh accepts a PREFIX, and "|" separates alternatives."""
    got_s = " ".join("0x%02x" % b for b in got)
    for alt in expect.split("|"):
        alt = alt.strip()
        if got_s.startswith(alt.lower()):
            return True
    return False


def panel_sees(panel, dump):
    """True / False / None(unverifiable) for this definition against this dump."""
    chain = stages(panel)
    if not chain:
        return None
    unknown = False
    for st in chain:
        addr = int(st["addr"], 16) if st["addr"] else None
        got = read_dump(dump, addr, parse_bytes(st["write"]), st["read"])
        if got is None:
            unknown = True
            continue
        if not expect_matches(got, st["expect"]):
            return False                 # one failed stage is a definite no
    return None if unknown else True


# ------------------------------------------------------------------ checks ---

def static_checks(panels):
    """Things that are wrong on their face, no dump required."""
    problems = []
    for p in panels:
        chain = stages(p)
        if not chain:
            problems.append("%s: no DETECT_EXPECT, so it can never be detected"
                            % p["id"])
            continue
        for st in chain:
            if st["read"] > CCI_MAX_READ:
                problems.append(
                    "%s: probe %s reads %d bytes. The CCI controller on this "
                    "carrier refuses anything over %d, so this cannot work on "
                    "the hardware it is written for."
                    % (p["id"], st["n"], st["read"], CCI_MAX_READ))
            want = max(len(parse_bytes(a)) for a in st["expect"].split("|"))
            if want > st["read"]:
                problems.append(
                    "%s: probe %s expects %d bytes but only reads %d"
                    % (p["id"], st["n"], want, st["read"]))
        if not p.get("PANEL_ID"):
            problems.append("%s: no PANEL_ID" % p["id"])
        elif p["PANEL_ID"] != p["id"]:
            problems.append("%s: PANEL_ID is %r, which does not match the "
                            "filename" % (p["id"], p["PANEL_ID"]))
    return problems


def replay(panels, dumps, verbose=False):
    problems = []
    for d in dumps:
        matched, unsure = [], []
        for p in panels:
            verdict = panel_sees(p, d)
            if verdict is True:
                matched.append(p["id"])
            elif verdict is None:
                unsure.append(p["id"])

        if verbose:
            print("  %-26s matched: %s%s"
                  % (d["name"], ", ".join(matched) or "NOTHING",
                     ("   (unverifiable: %s)" % ", ".join(unsure)) if unsure else ""))

        if d["name"] not in matched:
            problems.append(
                "%s: its own definition does not match its recorded dump%s"
                % (d["name"],
                   " (unverifiable against: %s)" % ", ".join(unsure)
                   if d["name"] in unsure else ""))
        if len(matched) > 1:
            problems.append(
                "COLLISION: %s is matched by %d definitions - %s. Detection "
                "would stop and ask rather than guess, which is safe but means "
                "nobody can install either panel without picking by hand."
                % (d["name"], len(matched), ", ".join(matched)))
    return problems


# --------------------------------------------------------------- suggest ----

# Probes worth trying, best first. The order is a judgement this repository has
# paid for: a digitizer's reported size is a property of the glass, while
# thresholds are tuning that can move between production batches, so a
# fingerprint built on thresholds eventually rejects a genuine panel.
CANDIDATES = [
    ("product ID",       PRODUCT_ID_REG, 4),
    ("touch resolution", 0x8048, 4),
    ("config version",   0x8047, 1),
    ("thresholds",       0x8053, 2),
]


def suggest(dump, others):
    """Propose the shortest chain that separates this panel from every other."""
    print("Dump: %s  (controller at 0x%02x)" % (dump["name"], dump["addr"] or 0))
    print("")

    chosen, excluded = [], set()
    for label, reg, n in CANDIDATES:
        write = [reg >> 8, reg & 0xFF]
        mine = read_dump(dump, dump["addr"], write, n)
        if mine is None:
            continue

        newly = set()
        for o in others:
            if o["name"] in excluded:
                continue
            theirs = read_dump(o, o["addr"], write, n)
            if theirs is None or theirs != mine:
                newly.add(o["name"])

        keep = not chosen or newly
        mark = "USE " if keep else "    "
        print("%s%-18s 0x%04x x%d -> %s%s"
              % (mark, label, reg, n,
                 " ".join("0x%02x" % b for b in mine),
                 ("   rules out: " + ", ".join(sorted(newly))) if newly else
                 "   (separates nothing new)"))
        if keep:
            chosen.append((label, reg, n, mine))
            excluded |= newly
        if len(excluded) == len(others):
            break

    print("")
    remaining = sorted(o["name"] for o in others if o["name"] not in excluded)
    if remaining:
        print("STILL AMBIGUOUS against: %s" % ", ".join(remaining))
        print("")
        print("Those panels answer identically everywhere this looked. Dump")
        print("more of the config block and diff it:")
        print("    sudo tools/goodix-config.sh dump mine.txt")
        print("    tools/goodix-config.sh diff theirs.txt mine.txt")
        print("")
        print("If nothing differs anywhere, say so in the pull request. Two")
        print("panels that are genuinely identical on the bus are a fact about")
        print("the hardware, and detection is built to stop and ask rather")
        print("than guess - see the 8 inch and 10.1 inch.")
    else:
        print("This chain identifies the panel uniquely against every dump on")
        print("file. Paste into your .panel file:")
        print("")
        for i, (label, reg, n, val) in enumerate(chosen):
            sfx = "" if i == 0 else str(i + 1)
            print('DETECT%s_WRITE="0x%02x 0x%02x"%s'
                  % (sfx, reg >> 8, reg & 0xFF,
                     "" if i else "          # %s" % label))
            print('DETECT%s_READ="%d"' % (sfx, n))
            print('DETECT%s_EXPECT="%s"   # %s'
                  % (sfx, " ".join("0x%02x" % b for b in val), label))
        if len(chosen) > 1:
            print("")
            print("Every stage must match, so each one is there to exclude")
            print("something - do not drop one because it looks redundant.")
    return 0 if not remaining else 1


# ------------------------------------------------------------------- main ---

def main(argv):
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--suggest", metavar="DUMP",
                    help="propose a fingerprint for a new panel's dump")
    ap.add_argument("--dumps", default=os.path.join(ROOT, "bench", "results",
                                                    "goodix"),
                    help="directory of recorded dumps")
    ap.add_argument("-v", "--verbose", action="store_true")
    a = ap.parse_args(argv)

    panels = [load_panel(p) for p in sorted(glob.glob(
        os.path.join(ROOT, "panels", "*.panel")))
        if "TEMPLATE" not in p]
    dumps = [load_dump(p) for p in sorted(glob.glob(
        os.path.join(a.dumps, "*.txt")))]

    if a.suggest:
        mine = load_dump(a.suggest)
        others = [d for d in dumps if d["name"] != mine["name"]]
        if not others:
            print("no other dumps to compare against")
            return 1
        return suggest(mine, others)

    print("%d panel definitions, %d recorded panels" % (len(panels), len(dumps)))

    problems = static_checks(panels)
    if a.verbose or True:
        print("")
    problems += replay(panels, dumps, verbose=a.verbose)

    print("")
    if problems:
        for msg in problems:
            print("FAIL  %s" % msg)
        print("")
        print("%d problem(s)." % len(problems))
        return 1

    print("every recorded panel is matched by exactly one definition, and it "
          "is its own.")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))

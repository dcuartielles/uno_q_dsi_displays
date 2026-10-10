# Adding a panel

Pull requests adding a new display are welcome. This page is about what makes
one reviewable, because there is an awkward fact at the centre of it:

**the reviewer does not have your panel, and never will.**

So a panel pull request cannot be judged by trying it. It is judged on
evidence, and the evidence has to be the raw answers your hardware gave - not a
description of them. Everything below exists to make that evidence collectable
in one command and checkable in one second.

## The short version

On the board, with the panel attached:

```bash
sudo tools/new-panel.sh
```

That is a conversation, not a command. It works out which upstream panel you
have, measures the fingerprint off your hardware, writes the definition,
installs it, puts a moving pattern on the screen and asks you whether it looks
right - then leaves a pull request ready to send. Two of those steps cannot be
automated: which panel you bought, and whether the picture is correct.

**Nothing is sent anywhere unless you say so.** The bundle contains your
board's model, kernel and `dmesg`; review it first.

If you would rather drive it yourself, the pieces underneath are all usable
alone:

```bash
sudo tools/capture-panel.sh waveshare-5in5-touch-a
```

That writes `submissions/<name>/` with the I2C scan, the touch controller's
config dump, the DRM state, the relevant `dmesg`, and a **proposed
fingerprint** worked out by comparing your panel against every panel anyone has
recorded. It also leaves a `DRAFT.panel` to fill in.

Then: finish the definition, install it, look at the screen, and open a pull
request with the evidence pasted in.

## Why the config dump is the important file

Three times in this repository a new panel has been confidently detected as a
*different* panel:

| | |
| --- | --- |
| Waveshare 7.0inch C | reports product ID `911` - same as the Arduino 5 inch |
| Waveshare 8.8inch | same product ID as the 8/10.1/12.3 inch **and** the same thresholds as the 10.1 inch |
| Arduino 8 vs 10.1 inch | byte-identical except two threshold bytes; nothing else separates them |

Every one was caught by a person, by hand, late, because they happened to
remember another panel. That does not scale, and it is not a fair thing to ask
of a reviewer.

Your dump fixes it. A detection definition is a short script of reads against
the touch controller; a dump is a record of what that controller answers. So
the dump is enough to ask **"what would this definition see if that panel were
plugged in?"** without the panel being plugged in:

```bash
python3 tools/check-fingerprints.py -v
```

replays every definition against every recorded panel and insists each one is
matched by exactly one definition - its own. It runs in CI, needs no hardware,
and takes a second.

It compares **like with like**: only panels recorded at the same controller
address. Nobody has recorded what a Goodix panel answers at 0x45, so claiming
your 0x45 fingerprint is ambiguous against one would be inventing a finding.
Where there is no evidence, it says so rather than guessing in either
direction.

The bargain is mutual: **contribute the dump, and nobody can add a panel after
yours that breaks yours without CI noticing.**

## Which upstream entry is your panel?

A DSI panel carries **no EDID**. Its timings, lane count and initialisation
sequence are not on it and never will be - no amount of probing produces them.

What it does tell you is its digitizer resolution, and Raspberry Pi's driver
already holds the mode and init sequence for seventeen Waveshare panels. So
the job is to work out *which* of those you are holding:

```bash
python3 tools/match-upstream.py submissions/<id>/goodix-0x5d.txt
python3 tools/match-upstream.py --list        # the whole table
```

Resolution settles it for five of the seven distinct resolutions upstream. The
other two do not:

| Reported | Candidates |
| --- | --- |
| 800x1280 | 4 entries, 2 or 4 lanes |
| 720x1280 | 8 entries, 65 to 83.3 MHz |

The tool will not choose for you there, deliberately. Picking wrong gives a
connected connector, the right driver, a clean `dmesg` and a garbled picture -
the failure this repository has met most often. Go by what the panel is sold
as, then **look at the screen**.

If nothing matches, your panel is not in that driver and the timings have to
come from the vendor's own sources - Waveshare publish per-panel drivers. That
is the *described* path.

## What the pull request must contain

1. **`panels/<name>.panel`** - the definition.
2. **`bench/results/<controller>/<name>.txt`** - the signature dump, so CI can
   replay it. `goodix/` for a Goodix at 0x5d, `attiny/` for a Raspberry Pi
   style ATTINY at 0x45, a new directory for anything else. `capture-panel.sh`
   prints the exact copy command for whichever one your panel has.
3. **Evidence in the description** - the template asks for it:
   - the output of `sudo ./scripts/detect-panel.sh` showing your panel matched
     and every other rejected
   - `python3 tools/check-fingerprints.py -v` passing
   - the DRM connector, mode, and the driver that bound
   - **a photograph of the panel running** - a number or the spiral on the glass
   - whether **touch** works, confirmed with a finger

## Things that get a pull request sent back

**Guessed values presented as measured.** If you did not verify something, say
so in the file. Several definitions here carry notes like *"UNVERIFIED - on a
square panel the axes cannot be told apart by their reported extents"*. That is
worth more than a confident wrong value, because the next person knows what to
check.

**A fingerprint built on tuning.** Prefer values that are properties of the
hardware. A digitizer's reported resolution is a property of the glass;
thresholds are tuning that can move between production batches, and a
fingerprint built on those eventually rejects a genuine panel. `--suggest`
already prefers the right ones.

**A probe longer than 12 bytes.** The Qualcomm CCI controller on this carrier
refuses any read over 12 bytes. `check-fingerprints.py` fails the build on it,
but it is worth knowing why rather than fighting the error.

**A stage that excludes nothing.** Every probe must rule something out. One
that does not only adds a way to fail - see the Arduino 8 inch, which
deliberately has no third stage.

**"It works" without a picture.** Every software check in this repository can
pass while the screen shows garbage: the connector reports connected, the mode
is right, the driver bound, `dmesg` is clean, and the picture is torn. Only an
eye catches that, which is why a photograph is required.

## Panels that genuinely cannot be told apart

Sometimes two panels are identical on the bus. The Arduino 8 inch and 10.1 inch
are: same product ID, same config version, same touch resolution, same panel
driver, same DRM mode - measured on both, on the same board - and they need
different overlays.

That is a fact about the hardware, not a gap in your work. Detection handles it
by **stopping and asking** rather than guessing, and it will do the same for
yours. Say so in the pull request, and in the definition, and move on.

## The three integration paths

Which one you need is a property of your panel, not a preference. See
[docs/ADDING-A-PANEL.md](docs/ADDING-A-PANEL.md) for the detail.

| | |
| --- | --- |
| **stock** | the kernel has the driver and Arduino ships the overlay - select it, build nothing |
| **described** | timings written out in the `.panel` file, drivers patched |
| **derived** | an upstream driver trimmed to your panel, overlay derived from Arduino's 10.1 inch |

Most new panels are **derived**, and most derived panels need a `.panel` file
and no code at all - the last three did.

## Keeping the recordings honest

The replay above checks definitions against recorded dumps. It cannot check
that a dump still describes the hardware - and where a probe's expected bytes
were taken from its own dump, the check is comparing a value with its own
source.

So panels get put back on a bench periodically.
[docs/RETEST-CHECKLIST.md](docs/RETEST-CHECKLIST.md) is the procedure, and
carries whichever run is currently outstanding.

## Running the checks before you push

All of these work on any machine, with no board attached:

```bash
python3 tools/check-fingerprints.py -v    # no fingerprint collides
python3 tools/check-docs.py               # docs still agree with the measurements
python3 bench/install-matrix.py           # patches still apply to shipped kernels
for f in scripts/*.sh lib/*.sh tools/*.sh; do sh -n "$f" || echo "FAIL $f"; done
```

CI runs the same ones.

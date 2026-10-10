# Panel re-test checklist

What still needs putting on a bench, broken down by **which part** of each
panel is in doubt - because "re-test the 10.1 inch" is not an instruction
anybody can act on.

## The panels, and which line they belong to

Waveshare sells two lines, and the difference is the wiring:

| Line | Connection | Consequence |
| --- | --- | --- |
| **DSI LCD** | the wide-narrow DSI flex alone, power drawn through it | cannot carry a large panel, so the line stops at small sizes |
| **DSI-TOUCH-A / -C** | a pure DSI connector **plus its own 5V lead** | can drive large panels |

Both lines have a touchscreen. They differ in how they are wired and powered,
not in whether you can touch them.

### What this repository supports

Read from the panel definitions. "not recorded" means the file does not say -
not that the answer is no.

| Panel | Line | Resolution | DSI lanes | Touch controller | Detected via | Own 5V lead |
| --- | --- | --- | --- | --- | --- | --- |
| Waveshare 4.3inch + 5inch | **LCD** | 800×480 | 1 | FT5x06 @ `0x38` | ATTINY @ `0x45` | no - powered over the flex |
| Waveshare 4.0inch C | TOUCH-C | 720×720 *(round)* | 2 | Goodix GT9271 @ `0x5d` | same chip | not recorded |
| Waveshare 7.0inch C | TOUCH-C | 1024×600 | 2 | Goodix GT911 @ `0x5d` | same chip | not recorded |
| Arduino 5inch | TOUCH-A | 720×1280 | not recorded | Goodix GT911 @ `0x5d` | same chip | not recorded |
| Arduino 8inch | TOUCH-A | 800×1280 | not recorded | Goodix GT9271 @ `0x5d` | same chip | not recorded |
| Waveshare 8.8inch | TOUCH-A | 480×1920 | 2 | Goodix GT9271 @ `0x5d` | same chip | not recorded |
| Arduino 10.1inch | TOUCH-A | 800×1280 | not recorded | Goodix GT9271 @ `0x5d` | same chip | not recorded |
| Arduino 12.3inch | TOUCH-A | 720×1920 | 4 | Goodix GT9271 @ `0x5d` | same chip | **yes** - 5V at 1A or more, documented |

The 12.3 inch is the only panel whose power lead is written down, and it is
there because a faulty one cost most of an afternoon looking like a software
fault. The others are presumably the same by line, but presumably is not
recorded - worth filling in as panels come back to a bench.

Note the two detection arrangements. On the LCD line the fingerprint reads the
**ATTINY at 0x45**, not the touch controller, because the FT5x06 is held in
reset until a driver releases it - it is silent exactly when detection needs
it. On the TOUCH line the Goodix answers for itself.

### Which chips we hold signatures for

Detection can only be checked against chips somebody recorded. This is the
state of that evidence:

| Chip | On | Signatures held |
| --- | --- | --- |
| Goodix @ `0x5d` | every TOUCH panel | **6 of 7** - the 4.0 inch C is missing |
| ATTINY @ `0x45` | LCD line | 1 of 1 |
| GPIO chip @ `0x45` | **every TOUCH panel** | **0 of 7** |
| FT5x06 @ `0x38` | LCD line | 0 - and deliberately so |

**The third row is a blind spot.** The LCD definition probes `0x45` expecting
`c3|de`, and every TOUCH panel has a chip at `0x45` too - a Waveshare GPIO
chip rather than an ATTINY, but at the same address. `docs/ADDING-A-PANEL.md`
says it plainly: *"both panels shipped here occupy 0x45, so for them the
address proves nothing"*.

`check-fingerprints.py` compares only panels recorded at the same address, so
today it proves the seven TOUCH panels do not collide **with each other**, and
proves **nothing** about LCD against TOUCH in either direction. One direction
has been seen by eye - the 4.3 inch answered nothing at `0x5d` on 10-09, so
the Goodix definitions reject it - but that was observed, not recorded.

Capturing `0x45` on each TOUCH panel closes it. `capture-panel.sh` now does
that on every panel, and a panel record can hold several controllers, so the
dump has somewhere to live. **Do it at every bench visit below.**

The FT5x06 row is not a gap: detection deliberately never reads it, because it
is held in reset until a driver releases it and is silent exactly when
detection needs it. That is why the LCD line is fingerprinted via its ATTINY.


### Coverage by size

We do not have both lines at any size except 5 inch:

| Size | LCD | TOUCH |
| --- | :-: | :-: |
| 4.0in | — | ✅ C |
| 4.3in | ✅ | — |
| 5in | ✅ | ✅ A |
| 7.0in | — | ✅ C |
| 8.0in | — | ✅ A |
| 8.8in | — | ✅ A |
| 10.1in | — | ✅ A |
| 12.3in | — | ✅ A |

So any claim of the form "the LCD line behaves like this" rests on one
definition covering two physical panels. Worth remembering before generalising
from it.

## Why a bench is needed at all

`tools/check-fingerprints.py` proves the definitions are **mutually consistent
with the recorded dumps**. It cannot prove a dump still describes the hardware,
and where a probe's expected bytes were taken **from its own dump**, the replay
compares a value with its own source. CI stays green while a real panel fails.

That covers DETECT only. Nothing offline says anything about PICTURE or INPUT.

## What is in doubt, and where

Three things get tested, and they fail independently. These are **not** the
product lines - every panel has all three:

| | What it is | What proves it |
| --- | --- | --- |
| **PICTURE** | the image is right | an eye on a moving pattern |
| **DETECT** | the fingerprint identifies this panel and no other | one match, and a fresh dump matching the recorded one |
| **INPUT** | the digitizer works, the right way round | a finger, and coordinates landing where you pressed |

Bench date = the last time that physical panel was verified.

| Panel | Line | Bench | PICTURE | DETECT | INPUT |
| --- | --- | --- | :-: | :-: | :-: |
| Waveshare 4.3/5inch | LCD | 10-09 | ✅ | ✅ | 🟡 |
| Waveshare 4.0inch C | TOUCH-C | 09-15 | ✅ | 🔴 | 🟠 |
| Waveshare 7.0inch C | TOUCH-C | 09-15 | ✅ | ✅ | 🟡 |
| Arduino 5inch | TOUCH-A | 09-09 | ✅ | 🟠 | ✅ |
| Arduino 8inch | TOUCH-A | 09-08 | 🟡 | 🟡 | 🟠 |
| Waveshare 8.8inch | TOUCH-A | 09-16 | ✅ | ✅ | 🟡 |
| Arduino 10.1inch | TOUCH-A | 09-08 | 🟡 | 🟠 | 🟠 |
| Arduino 12.3inch | TOUCH-A | 09-09 | 🟠 | 🟡 | ✅ |

🔴 never verified · 🟠 verified, then the code under it changed · 🟡 verified,
but indirectly or long ago · ✅ current

Record disputed? Say so in the Results table and correct the panel file. A
bench date nobody wrote down is worth less than a memory, but both are worth
less than a finger on the glass today.

### The one genuine red

**The 4.0 inch C has no recorded signature.** The only definition never
replayed against real hardware - a file that does not exist, not an inference.
Its touch orientation is also marked unverified in the panel file: it is
square, so the axes cannot be deduced from the reported extents.

### The rest, briefly

- **🟠 5 inch and 10.1 inch DETECT** - each gained a probe stage (09-15, 09-16)
  *after* that panel was last on a bench. Never answered by real hardware.
- **🟠 12.3 inch PICTURE** - the derived install path changed on 09-15 (the
  private `unoq,` compatible, the generic patcher). Not installed with it since.
- **🟠 8 inch and 10.1 inch INPUT** - neither has run the *patched* `goodix_ts`,
  whose reads are split into 12-byte chunks for the CCI controller. The 1.8.0
  changelog claims touch was broken on them before that patch, but that claim
  is an inference from the shared controller rather than a measurement, and
  dcuartielles recalls testing touch on every panel. Either way the patched
  driver is code those panels have not run.
- **🟠 4.0 inch INPUT** - orientation unverified, see above.
- **🟡 8 inch / 10.1 inch PICTURE** - the stock install path changed 09-09,
  after their bench. Probably benign, cheap while they are out.
- **🟡 7.0 / 8.8 inch INPUT** - touch confirmed by finger, but orientation
  *deduced* from reported extents rather than checked by pointing.
- **🟡 4.3/5inch LCD INPUT** - the device appeared on 10-09 but the run ended
  before a finger confirmed it.
- **🟡 every panel's DETECT** - `detect-panel.sh` gained the stuck-bus guard on
  10-08, run cleanly on the LCD panel since and nowhere else. Rides along free.

## The three tests

### PICTURE

```bash
sudo ./scripts/detect-panel.sh --apply
sudo reboot
# after it is back:
sudo ./scripts/show-spiral.sh --until-touch      # round or square panels
sudo ./scripts/show-tunnel.sh --until-touch      # wide panels; fills the corners
```

- [ ] connector `connected`, at the expected mode
- [ ] the expected driver bound to `5e94000.dsi.0`
- [ ] **the picture is right to the eye** - no tearing, shear or stepped edges

The moving patterns are the honest test: a framebuffer written once and then
frozen photographs exactly like one being driven properly, so motion is the
only thing that proves the panel is still being refreshed.

### DETECT

```bash
sudo ./scripts/detect-panel.sh
sudo tools/capture-panel.sh <panel-id>
tools/goodix-config.sh diff bench/results/goodix/<panel-id>.txt \
                            submissions/<panel-id>/goodix-0x5d.txt
```

`capture-panel.sh` writes **both** controllers - `goodix-0x5d.txt` and
`ctrl-0x45.txt`. Keep both:

```bash
cp submissions/<id>/goodix-0x5d.txt bench/results/goodix/<id>.txt
mkdir -p bench/results/addr-0x45
cp submissions/<id>/ctrl-0x45.txt   bench/results/addr-0x45/<id>.txt
```

The second one is what lets the LCD definition be checked against this panel
at all.


- [ ] **exactly one** match, and it is the right panel
- [ ] every other definition rejected **with a reason**, not silently
- [ ] the fresh dump is identical to the recorded one, or the difference is
      understood and written down
- [ ] the stuck-bus guard did not fire on a healthy bus
- [ ] **`0x45` captured** - the one that closes the LCD/TOUCH blind spot

### INPUT

Function first, then orientation - they are different questions.

```bash
sudo ./scripts/test-touch.sh        # reports ABS_MT_POSITION for 20 seconds
```

- [ ] events appear at all - on the 8 and 10.1 inch this is the open question
- [ ] press **top-left**: both coordinates near their minimum
- [ ] press **bottom-right**: both near their maximum
- [ ] press along the **long edge**: the coordinate that moves is the one that
      matches the framebuffer's long axis

If the axes are transposed or run backwards, set `TOUCH_SWAP_XY`,
`TOUCH_INVERT_X`, `TOUCH_INVERT_Y` in the `.panel` file and reinstall. On a
square panel the extents cannot tell you - only pointing can.

## Suggested order

Four panels, about an hour, highest value first.

1. **10.1 inch** - 🟠 input, 🟠 detect, 🟡 picture. All three in one swap.
2. **8 inch** - 🟠 touch, 🟡 the rest. Do it straight after: its thresholds are
   the only thing separating it from the 10.1 inch, so confirm that too.
3. **4.0 inch C** - 🔴 detect, 🟠 input orientation. Also the only way to
   exercise the Goodix branch of `capture-panel.sh`, untested since 1.14.1.
4. **5 inch** - 🟠 detect only. Quick.

Then if there is appetite: **12.3 inch** for its 🟠 install path.

## Afterwards

```bash
cp submissions/<id>/goodix-0x5d.txt bench/results/goodix/<id>.txt
python3 tools/check-fingerprints.py -v
python3 tools/check-docs.py
```

Commit the refreshed dumps, and update the **Bench** column above. A recording
confirmed against hardware is worth more than the date on the old one.

## To settle while the panels are out

- **The 8.8 inch carries a redundant probe stage.** `--suggest` found its
  product ID plus touch resolution already identify it, so the threshold stage
  excludes nothing. This repository's own rule is that a stage adding no way to
  succeed only adds a way to fail - but trim it with the panel attached.
- **Confirm the 8 inch and 10.1 inch still cannot be told apart.** Same product
  ID, config version, touch resolution, driver and mode; differing only in two
  threshold bytes. If a newer batch differs anywhere else, that is worth
  knowing.

## Results

| Panel | Date | PICTURE | DETECT | INPUT | Notes |
| --- | --- | --- | --- | --- | --- |
| arduino-10in-touch-a | | | | | |
| arduino-8in-touch-a | | | | | |
| waveshare-4in-touch-c | | | | | |
| arduino-5in-touch-a | | | | | |
| arduino-12in-touch-a | | | | | |

# Panel re-test checklist

What still needs putting on a bench, broken down by **which part** of each
panel is in doubt - because "re-test the 10.1 inch" is not an instruction
anybody can act on.

## Three things, and they fail independently

A panel is three subsystems that break in different ways, are fixed by
different code, and need different evidence:

| | What it is | What proves it | What breaks it |
| --- | --- | --- | --- |
| **LCD** | the picture | an eye on a moving pattern | panel driver, timings, overlay, the install path |
| **DETECT** | the I2C fingerprint that identifies the panel | `detect-panel.sh` picking exactly one, and a fresh dump matching the recorded one | the `DETECT_*` fields, `detect-panel.sh` |
| **TOUCH** | the digitizer actually working, the right way round | a finger, and coordinates that land where you pressed | the touch driver patches, `TOUCH_SWAP_XY` / `INVERT_*` |

A panel can have a perfect picture and dead touch. It can have working touch
mapped backwards. It can be detected as something else entirely and still light
up. These are not one test.

## Why a bench is needed at all

`tools/check-fingerprints.py` proves the definitions are **mutually consistent
with the recorded dumps**. It cannot prove a dump still describes the hardware,
and where a probe's expected bytes were taken **from its own dump**, the replay
compares a value with its own source. CI stays green while a real panel fails.

That covers DETECT only. Nothing offline says anything at all about LCD or
TOUCH.

## What needs what

Bench date = the last time that physical panel was verified. Compared against
when each subsystem's code last changed.

| Panel | Bench | LCD | DETECT | TOUCH |
| --- | --- | :-: | :-: | :-: |
| Arduino 5inch | 09-09 | ✅ | 🟠 | ✅ |
| Arduino 8inch | 09-08 | 🟡 | 🟡 | 🟠 |
| Arduino 10.1inch | 09-08 | 🟡 | 🟠 | 🟠 |
| Arduino 12.3inch | 09-09 | 🟠 | 🟡 | ✅ |
| Waveshare 4.0inch C | 09-15 | ✅ | 🔴 | 🟠 |
| Waveshare 7.0inch C | 09-15 | ✅ | ✅ | 🟡 |
| Waveshare 800×480 | 10-09 | ✅ | ✅ | 🟡 |
| Waveshare 8.8inch | 09-16 | ✅ | ✅ | 🟡 |

🔴 never verified · 🟠 verified, then the code under it changed · 🟡 verified,
but indirectly or long ago · ✅ current

Record disputed? Say so in the Results table and correct the panel file. A
bench date nobody wrote down is worth less than a memory, but both are worth
less than a finger on the glass today.

### The two that matter most

**🟠 The 8 inch and 10.1 inch have never had touch verified against the driver
they would run today.** Both were benched on 09-08; the Goodix 12-byte read
fix landed on 09-09.

There is a disagreement in the record here, and it is worth stating rather than
resolving by assertion. The 1.8.0 changelog says touch on the 5, 8 and 10.1
inch was *"checked for the presence of an input device"* rather than by a
finger, and asserts the fault *"affects the 5, 8 and 10.1 inch too"* - but that
assertion is an inference from the shared controller and the shared 12-byte
ceiling, not a measurement on those panels. dcuartielles recalls testing touch
on every panel.

Both readings leave the same gap, which is why it does not need settling first:

- if touch was broken then, it has never been seen working;
- if touch worked then, it worked with the **unpatched** driver, and since
  09-09 these panels would run `goodix_ts` with reads split into 12-byte
  chunks - code they have never run.

Thirty seconds with a finger settles it, and also corrects the record.

**🔴 The 4.0 inch C has no recorded signature.** The only definition never
replayed against real hardware. Its touch orientation is also marked unverified
in the panel file - it is square, so the axes cannot be deduced from the
reported extents the way they can on a tall panel.

### The rest, briefly

- **🟠 5 inch and 10.1 inch DETECT** - each gained a probe stage (09-15, 09-16)
  *after* that panel was last on a bench. Those stages have never been answered
  by real hardware.
- **🟠 12.3 inch LCD** - the derived install path changed on 09-15 (the private
  `unoq,` compatible, and the generic patcher replacing the 12.3-specific one).
  The panel has not been installed with that code.
- **🟠 4.0 inch TOUCH** - orientation unverified, see above.
- **🟡 8 inch / 10.1 inch LCD** - the stock install path changed on 09-09,
  after their bench. Probably benign, cheap to confirm while they are out.
- **🟡 7.0 / 8.8 inch TOUCH** - touch confirmed with a finger, but orientation
  was *deduced* from the reported extents rather than checked by pointing.
- **🟡 800×480 TOUCH** - the device appeared on 10-09 but the run was cut short
  before a finger confirmed it.
- **🟡 every panel's DETECT** - `detect-panel.sh` gained the stuck-bus guard on
  10-08. It has run cleanly on the 800×480 since, and nowhere else. It rides
  along free with any DETECT test below.

## The three tests

### LCD

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

- [ ] **exactly one** match, and it is the right panel
- [ ] every other definition rejected **with a reason**, not silently
- [ ] the fresh dump is identical to the recorded one, or the difference is
      understood and written down
- [ ] the stuck-bus guard did not fire on a healthy bus

### TOUCH

Function first, then orientation - they are different questions.

```bash
sudo ./scripts/test-touch.sh        # reports ABS_MT_POSITION for 20 seconds
```

- [ ] events appear at all - this is what the 8 and 10.1 inch have never shown
- [ ] press **top-left**: both coordinates near their minimum
- [ ] press **bottom-right**: both near their maximum
- [ ] press along the **long edge**: the coordinate that moves is the one that
      matches the framebuffer's long axis

If the axes are transposed or run backwards, set `TOUCH_SWAP_XY`,
`TOUCH_INVERT_X`, `TOUCH_INVERT_Y` in the `.panel` file and reinstall. On a
square panel the extents cannot tell you - only pointing can.

## Suggested order

Four panels, about an hour, highest value first.

1. **10.1 inch** - 🟠 touch, 🟠 detect, 🟡 lcd. All three in one swap.
2. **8 inch** - 🟠 touch, 🟡 the rest. Do it straight after: its thresholds are
   the only thing separating it from the 10.1 inch, so confirm that too.
3. **4.0 inch C** - 🔴 detect, 🟠 touch orientation. Also the only way to
   exercise the Goodix branch of `capture-panel.sh`, untested since 1.14.1.
4. **5 inch** - 🟠 detect only. Quick.

Then if there is appetite: **12.3 inch** for its 🟠 LCD install path.

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

| Panel | Date | LCD | DETECT | TOUCH | Notes |
| --- | --- | --- | --- | --- | --- |
| arduino-10in-touch-a | | | | | |
| arduino-8in-touch-a | | | | | |
| waveshare-4in-touch-c | | | | | |
| arduino-5in-touch-a | | | | | |
| arduino-12in-touch-a | | | | | |

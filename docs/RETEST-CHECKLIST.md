# Panel re-test checklist

A procedure for putting panels back on a bench and confirming detection still
works end to end, plus the specific run that is currently outstanding.

## Why this is needed at all

`tools/check-fingerprints.py` replays every definition against every recorded
dump and proves they are **mutually consistent**. It cannot prove the dumps
still describe the hardware, and there is a circularity worth naming:

> When a definition's expected bytes were taken **from its own dump**, the
> replay is checking a value against its own source. If the recording were
> unrepresentative, both would agree and the panel would still fail on a real
> bench.

That is exactly how the probes added in 1.11.0 and 1.13.0 were written. CI is
green and those stages have never been answered by a physical panel. Only
hardware tests the premise; the offline check tests the logic.

## The outstanding run

| | Panel | Why it is on the list |
| --- | --- | --- |
| 🔴 | **Waveshare 4.0inch C** | the only definition with **no recorded signature** - never replayed against real hardware. Also the only way to exercise the Goodix branch of `capture-panel.sh`, untested since 1.14.1 |
| 🟠 | **Arduino 5inch** | second probe added 2026-09-15 (the 7 inch collision); last on a bench ~09-09, so the probe **predates** every test of this panel |
| 🟠 | **Arduino 10.1inch** | third probe added 2026-09-16 (the 8.8 inch collision); last on a bench ~09-08, same problem |
| 🟡 | **Arduino 8inch** | definition unchanged, but its recording is the oldest (09-08) and its thresholds are the *only* thing separating it from the 10.1 inch. Cheap while the 10.1 is out |
| 🟡 | **Arduino 12.3inch** | optional. Unchanged definition, recording from 09-09 |

About an hour for the first four.

## Per panel

With the board **powered off**, swap the panel, then power up.

```bash
# 1. does detection still pick exactly one, and the right one?
sudo ./scripts/detect-panel.sh

# 2. capture a fresh signature
sudo tools/capture-panel.sh <panel-id>

# 3. does the hardware still say what we recorded?
tools/goodix-config.sh diff bench/results/goodix/<panel-id>.txt \
                            submissions/<panel-id>/goodix-0x5d.txt

# 4. install, reboot, and look at it
sudo ./scripts/detect-panel.sh --apply
sudo reboot
# after it comes back:
sudo ./scripts/show-spiral.sh --until-touch     # or show-tunnel.sh on a wide panel
```

### What counts as a pass

- [ ] detection reports **exactly one** match, and it is the right panel
- [ ] every other definition is rejected with a reason, not silently
- [ ] the fresh dump is **identical** to the recorded one, or the difference is
      understood and written down
- [ ] connector `connected`, at the expected mode
- [ ] the expected driver is bound to `5e94000.dsi.0`
- [ ] the picture is **correct to the eye** - every software check here can
      pass while the screen shows garbage
- [ ] **touch dismisses the pattern**, with a finger, on that glass

The last two are the ones no script can do. The spiral is the honest test: it
proves the panel is still being refreshed rather than showing one frame that
was painted and then froze, and the touch that dismisses it proves the
digitizer works.

### Record for each

```
panel:        <id>
date:         <when>
detection:    one match / collision / none      (paste the output)
dump vs file: identical / differs (how)
connector:    card0-DSI-1 <status> <mode>
driver:       <bound driver>
picture:      correct / wrong (how)
touch:        works / no / n/a
```

## Afterwards

```bash
# fresh signatures into the tree, including the 4.0 inch's first one
cp submissions/<id>/goodix-0x5d.txt bench/results/goodix/<id>.txt

python3 tools/check-fingerprints.py -v      # still exactly one match each
python3 tools/check-docs.py
```

Then commit the updated dumps. A recording refreshed against hardware is worth
more than the date on the old one.

## Two things to settle while the panels are out

- **The 8.8 inch carries a redundant probe stage.** `--suggest` found that its
  product ID plus touch resolution already identify it, so the threshold stage
  in the middle excludes nothing. The repository's own rule is that a stage
  adding no way to succeed only adds a way to fail. Worth trimming - but only
  with the panel attached to re-verify.
- **The 8 inch and 10.1 inch cannot be told apart.** Confirm this is still
  true rather than assuming it: same product ID, config version, touch
  resolution, driver and mode, differing only in two threshold bytes. If a
  newer batch differs anywhere else, that is worth knowing.

## Results

| Panel | Date | Detection | Dump | Picture | Touch | Notes |
| --- | --- | --- | --- | --- | --- | --- |
| waveshare-4in-touch-c | | | | | | |
| arduino-5in-touch-a | | | | | | |
| arduino-10in-touch-a | | | | | | |
| arduino-8in-touch-a | | | | | | |
| arduino-12in-touch-a | | | | | | |

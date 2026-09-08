# Changelog

## 1.7.0 - 2026-09-09

### Panels can now be recognised and refused

A `.panel` file may declare `UNSUPPORTED="<reason>"`. Detection then identifies
the panel, prints the reason, and stops - and `--select`, `--apply`,
`install.sh` and `40-verify.sh` all refuse it, because the check lives in
`load_panel()` which every path goes through.

This is more useful than not recognising the panel at all. "No known panel
recognised" reads as "nobody has added it yet, force one of the others", and
the old message said as much in its last line. It no longer suggests that.

### Added

- `panels/arduino-12in-touch-a.panel` - the **12.3 inch DSI-TOUCH-A**,
  recognised and refused. Arduino ships overlays for 5, 8 and 10.1 inch only,
  and this panel is **1920x720 landscape** where all three supported panels are
  portrait. The described-panel path is not a way round it either: that
  generator emits an overlay for Raspberry Pi style hardware (ATTINY at 0x45,
  edt-ft5x06 at 0x38) and this panel has a waveshare GPIO chip and a Goodix.

  Supporting it properly needs vendor DSI timings and a new overlay. That is
  real work, not a `.panel` file.

- Its Goodix config is on record in `bench/results/goodix/`, completing the set
  of four:

  | | resolution | config version | thresholds |
  | --- | --- | --- | --- |
  | 5 inch | 720x1280 | `0x46` | `5a 3c` |
  | 8 inch | 800x1280 | `0x82` | `5f 41` |
  | 10.1 inch | 800x1280 | `0x82` | `50 32` |
  | 12.3 inch | **1920x720** | `0x5c` | `64 32` |

  The two-stage fingerprints added in 1.6.0 rejected the 12.3 inch correctly
  and unprompted, which is the first evidence they discriminate against a panel
  they were not designed around.

### Safety note

On 2026-09-09 the 12.3 inch panel was connected to a board configured for the
5 inch overlay - the only configuration available, since none matches it - and
it smoked. The board was checked afterwards and is undamaged: 0 CCI timeouts,
no over-current or regulator faults logged, carrier I2C answering normally,
thermals normal, filesystem clean.

The cause was not established, and this changelog does not claim one. Bad FPC
seating and an incompatible power pinout are at least as plausible as the
overlay, and nothing logged points either way. What is certain is that driving
a panel with another panel's power-up sequence and timings had no chance of
working, so there was nothing to gain by trying - which is what this release
makes the tooling say out loud.

## 1.6.1 - 2026-09-09

### Fixed

- **`test-display.sh` sheared its own test pattern on 720-wide panels, and the
  result looked exactly like a panel driven with the wrong timings.**

  A framebuffer line is `stride` bytes, which is not always `width * bpp/8`. On
  the 5 inch the kernel pads each line to 2944 bytes where the naive
  calculation gives 2880, so every row landed 16 pixels further left than the
  one above - dense diagonal striping across the whole screen.

  It hid because the 800-wide panels are already 64-byte aligned and painted
  perfectly. Caught the first time the pattern was shown on the 5 inch.

  This mattered more than a cosmetic bug: `45-confirm-display.sh` asks a human
  whether the pattern looks right, so a working panel would have been reported
  as the wrong panel, and the suggested fix would have been to install a
  definition for hardware that was not attached.

### Measured

- The 5 inch config block is now on record
  (`bench/results/goodix/arduino-5in-touch-a.txt`), closing an unknown the
  previous release wrote into two panel files. All three panels differ in three
  independent places:

  | | config version | resolution | thresholds `0x8053` |
  | --- | --- | --- | --- |
  | 5 inch | `0x46` | 720x1280 | `5a 3c` |
  | 8 inch | `0x82` | 800x1280 | `5f 41` |
  | 10.1 inch | `0x82` | 800x1280 | `50 32` |

  The 5 inch keeps a single-stage fingerprint on purpose. Its product ID `911`
  already separates it from everything else known, so a second stage would add
  a way to fail without adding a way to succeed - thresholds can plausibly vary
  between production batches, and a stricter fingerprint on a panel that does
  not need one would eventually reject a genuine panel.

## 1.6.0 - 2026-09-08

### The 8 inch and 10.1 inch can now be told apart automatically

They report the same Goodix product ID, so the previous release made this a
human choice. It does not have to be. The controller's config block carries
panel-specific tuning past the product ID, and the two panels differ there:

```
offset   8 inch                      10.1 inch
0x8053   0x5f 0x41                   0x50 0x32     touch / release thresholds
0x806c   0x9a                        0xdb
0x807c   0x9e                        0x5e
```

`.panel` files may now declare a **second probe** (`DETECT2_WRITE`,
`DETECT2_READ`, `DETECT2_EXPECT`); both stages must match. The product ID still
identifies the family, and the thresholds separate the members - which matters,
because the second read alone would not exclude the 5 inch, whose value at that
offset is unknown. Identification stays positive rather than merely
non-contradictory.

Two things were checked before trusting it, and both could have sunk it:

- **It describes the panel, not the overlay.** Shown by accident and then on
  purpose: the 10.1 inch was read while the board still ran the 8 inch overlay
  and reported 10.1 inch values regardless. The touch node in the device tree
  carries only `compatible/name/reg/reset-gpio` - no config payload - so there
  is nothing for an overlay to have written.
- **It is stable.** Identical across two reboots and an overlay change. Some
  config bytes are calibration state the controller re-derives; a fingerprint
  built on those would work on a bench and drift in a workshop, which is worse
  than having none.

### Added

- `tools/goodix-config.sh` - dump a Goodix config block and diff two dumps. The
  single long read that would have found this months ago fails with "Operation
  not supported", which reads like a dead end and is actually the CCI transfer
  size limit - the same one behind the `edt-ft5x06` short-read patch. Eight
  bytes at a time works. Dumps for both panels are in `bench/results/goodix/`.
- `scripts/45-confirm-display.sh` - shows a test pattern, asks whether it looks
  right, and on "no" lists the other panels sharing this one's signature with
  the exact commands to try. Detection can tell you which panel is attached; it
  cannot tell you the picture came out right, and that is the failure this
  repository keeps meeting.

### Fixed

- **`test-display.sh` painted nothing while the desktop was running.** Xorg
  owns the display, so writing to `/dev/fb0` silently changed nothing - the
  command succeeded, the screen did not move, and the obvious conclusion was a
  broken panel. It now switches to a spare VT and back, as the benchmark's own
  pattern tool always did.

## 1.5.0 - 2026-09-08

### The 8 inch DSI-TOUCH-A works - and must be chosen by hand

Verified on hardware: connector `card0-DSI-1` at 800x1280, `/dev/fb0`
800,1280, backlight registered, `Goodix Capacitive TouchScreen` bound, zero DSI
errors, and the login screen photographed and checked by eye.

It is **indistinguishable from the 10.1 inch on the I2C bus**. Measured on both
panels, same board:

| | 8 inch | 10.1 inch |
| --- | --- | --- |
| Goodix product ID | `9271` | identical |
| Goodix config version | `0x82` | identical |
| Goodix touch resolution | 800x1280 | identical |
| panel driver bound | `jadard-jd9365da` | identical |
| DRM mode | 800x1280 | identical |

And they are **not interchangeable**. The 8 inch panel on the `10-dsi-touch-a`
overlay produces a connected connector, the right mode, the right driver, a
clean `dmesg` - and a garbled picture, vertical banding where the desktop
should be. The timings differ; the two `.dtbo` files are the same size and
differ visibly only in a compatible string, so comparing them is misleading.

`detect-panel.sh` therefore matches **both** definitions and refuses to choose,
printing the two `--select` commands instead. That is the correct outcome, not
a gap: guessing would give the wrong picture half the time, and every software
check would still report the display healthy.

### Fixed

- The ambiguous-match message told you to "make DETECT_EXPECT stricter", which
  is impossible when the panels are genuinely identical on the bus. It is now a
  chooser: it names the candidates, explains they cannot be told apart, prints
  the exact commands, and says that a garbled picture means the other one.
- `.panel` files gained `PANEL_DESC`, so `--list` and the chooser can say
  "Arduino 8inch DSI-TOUCH-A (800x1280)" rather than only an id.
- **`40-verify.sh` said "everything checks out" about a garbled screen.** It
  now says "every check that software can make has passed", and warns that a
  dark or garbled panel passes all of them. The script's own summary was
  making the mistake the rest of the repository documents.

### Corrected

An earlier draft of this release claimed the 8 inch and 10.1 inch overlays were
interchangeable, on the strength of the 8 inch coming up on the 10 inch overlay
with the connector connected, the mode right and the driver bound. **The screen
was garbled the whole time.** Checking DRM and calling it working is precisely
the mistake this repository exists to document, and it was made here on a board
with a camera pointed at it.

## 1.4.0 - 2026-09-08

### Added

- **The Arduino 10.1inch-DSI-TOUCH-A works**, and needs nothing built or
  patched. Verified on hardware: connector `card0-DSI-1` at 800x1280,
  `/dev/fb0` 800,1280, backlight registered, `Goodix Capacitive TouchScreen`
  bound, zero DSI errors, and the panel confirmed lit with a camera rather than
  taken on DRM's word.

  `detect-panel.sh` identifies it unaided and correctly rejects the 5 inch,
  which is not a given: the two share an I2C address, a touch driver and a
  backlight chip. Only the Goodix product ID separates them - ASCII `911`
  against `9271`, four bytes.

### Fixed

Three assumptions that held while the 5 inch was the only stock panel known:

- **Arduino ships three display options, not one** - `5-dsi-touch-a`,
  `8-dsi-touch-a` and `10-dsi-touch-a`, each with its own overlay. The stock
  path assumed the 5 inch slot everywhere, because that is the slot *described*
  panels hijack. Stock panels now use their own.
- **The stock panels do not share a panel driver.** The 5 inch is a Himax
  hx8394, the 10.1 inch a Jadard jd9365da. The driver check is read from the
  `.panel` file instead of hardcoded.
- **The driver check could not see a built-in driver.** It refused to install
  the 10.1 inch on a board that was already running it, because
  `jadard-jd9365da` is compiled into this kernel: `modinfo` cannot see it and
  this kernel does not list it in `modules.builtin` either. It is visible in
  sysfs, since a built-in driver registers at boot whether or not the hardware
  is present. All three places are checked now, and the output says which one
  answered.

  That check exists to avoid promising a panel that will not bind - and it did
  the opposite of its job to a panel that already had.

### Not added

The **8 inch** panel. Arduino ships the overlay and it would very likely work
the same way, but none has been tested here, and shipping a fingerprint nobody
has measured is worse than shipping none - it would match confidently and
wrongly.

## 1.3.1 - 2026-09-08

### Measured

- **30 cold boots on v1.3.0, all of them passing** — the first fully unattended
  run in this repository, power cut by a smart plug instead of by hand, which is
  the only reason N=30 was affordable. 12 of those boots had a badly wedged bus
  (85–154 CCI timeouts) and every one came up lit with the touchscreen present.

  This is also the first evidence that the deferred touch bring-up holds on
  **cold** boots. It was developed against warm reboots, and until this run
  "the mechanism should not care how the bus got wedged" was reasoning rather
  than measurement.

  The dark-panel figures move from 1 dark in 15 bug-hit boots to **1 in 45**,
  p = 0.0000028. The baseline is still only 5 boots and the README now says so
  out loud — five for five going dark is a strong signal from a small sample,
  and the confidence rests on that consistency and on the mechanism being
  understood, not on the size of the p-value.

### Fixed

- `tools/check-docs.py` quoted the p-value to five decimals, which rounded to
  `0.00000` as the sample grew. That compares equal to any small number, so the
  guard would have silently stopped checking the claim it exists to check.
  Seven decimals now, and the printed summary matches.

## 1.3.0 - 2026-09-08

### The touchscreen now survives a wedged boot

Measured over 32 warm reboots with the recovery service disabled, so that
anything working was the driver's own doing:

| | wedged boots with touch | clean boots |
| --- | --- | --- |
| released driver | **0 / 11** | 5 / 5 |
| with this change | **5 / 5** | 11 / 11 |

Fisher two-tailed **p = 0.00023**. Both arms were built and installed through
the identical DKMS path; only the driver source differed. Full method and raw
logs in [bench/results/touch/](bench/results/touch/README.md).

### What changed

`edt-ft5x06` stopped spinning on a bus it cannot have. Probe is split at the
first I2C access:

- a short **2 s synchronous window** catches an ordinary transient, as before
  but shorter;
- if only the *bus* is busy - as opposed to the device being absent - probe
  now **succeeds anyway**, and the rest of bring-up moves to a work item
  retrying every 5 s for up to 150 s, **holding nothing in between**.

That last part is the fix. The old code spun for 8 s and gave up, and while it
spun it starved the panel controller sharing that bus of the writes it needs to
light the backlight. The new retry generates roughly a twentieth of the traffic
and can wait far longer, so the two failures stop competing.

The poll loop had the same problem and got the same treatment: with no touch
IRQ on this carrier the driver polls at 60 Hz, and on a wedged boot every one of
those is a failed transfer. It now backs off to 500 ms after four consecutive
failures and returns to 60 Hz on the first good read. Fixing identify while
leaving the poll loop hammering would only have moved the contention.

The split point is `edt_ft5x06_ts_identify()`, the first I2C traffic, so a
retry always resumes from a clean state rather than re-registering resources. A
failure *after* identify is a genuine fault and is not retried.

### Fixed

- **The recovery service and the driver would have fought each other.** With
  the driver now recovering at ~27 s, the service began `modprobe -r` cycling
  at about the same moment, cancelling the driver's deferred work and
  restarting its wait - two mechanisms competing for one bus, which is what
  caused this bug originally. It now waits for the driver's own deadline and
  intervenes only if the driver gives up or goes quiet.
- `20-build-drivers.sh` warns when DKMS has an installed copy that will shadow
  what was just built. Running that script alone on a DKMS-registered board
  produced a clean build, a clean reboot, and no change whatsoever, because
  DKMS's copy in `updates/dkms/` wins the modprobe search. `update.sh` always
  ran both scripts, so only people iterating on a patch by hand were exposed.

### Added

- `bench/touch-boots.sh` and `bench/touch-analyze.py` - the harness and scoring
  for the measurement above. Warm reboots reproduce the touch failure (the
  wedge is self-inflicted by driver I2C traffic), so this needs no smart plug
  and nobody at the socket, unlike the cold-boot benchmark.

### Not fixed

The dark panel. The backlight sits behind the same wedged bus and the same lost
`REG_PORTC` writes, and nothing here touches it. `35-install-recovery.sh` still
re-asserts the backlight on every boot that needs it and is **not** removable;
only its touch role became a backstop.

## 1.2.0 - 2026-09-08

### Added

- **The Waveshare 4.3inch DSI LCD is verified working.** It needed no changes:
  the existing `waveshare-800x480` definition drove it correctly first time -
  800x480, backlight, touch, zero DSI errors. The definition now says so, and
  covers both the 4.3" and 5" variants explicitly.

  They stay **one** definition on purpose. The panels are identical
  electrically - same timings, same single DSI lane, same ICN6211 bridge, same
  ATTINY at 0x45, same FT5x06 at 0x38 - and nothing on the I2C bus tells them
  apart. Two files would give both the same fingerprint, and `detect-panel.sh`
  refuses to guess when two definitions match. One file is the correct answer
  here, not a shortcut.

- The ID values measured on the 4.3" panel are recorded in the definition
  (`REG_ID 0xc3`, FT5x06 chip `0x54` / firmware `0x0b` / vendor `0x79`), so
  that whoever next has a 5" in front of them can tell in one command whether
  the two can be distinguished after all.

### Changed

- **The Waveshare fingerprint is no longer marked unverified.** It was written
  from the driver source and from the *other* panel, because no Waveshare panel
  was available at the time. Measured now: `REG_ID` reads `0xc3`, exactly as
  predicted, and detection picked the right definition unaided on the first
  attempt with a panel it had never seen. The `0xde` alternative is still from
  source only and is kept - it is a different ATTINY firmware revision, and
  dropping it would silently stop recognising panels that report it.

### Known, unchanged

- Touch does not probe at boot on this panel: the CCI bus is wedged for the
  first ~100 seconds (176 timeouts measured on the verification boot), and the
  driver's identify retry only covers 8 s of that. The recovery service picks
  it up - `touch recovered after 4 attempt(s)` - so touch works, roughly a
  minute and a half after the desktop appears. This is the same behaviour as
  the 5" panel and the same root cause as the dark-panel bug; the real fix is a
  touch retry that yields the bus instead of holding it.

## 1.1.1 - 2026-09-08

### Changed

- The walkthrough for making a new panel auto-detectable
  ([ADDING-A-PANEL.md](docs/ADDING-A-PANEL.md#8-make-it-detectable)) is written
  for people who have never touched I2C. It went from "run `--scan`" straight to
  a finished `DETECT_` block, which skipped the only part that needed
  explaining. Now four steps with the real output at each one, including the
  cheapest way to find the right address - scan again with the panel unplugged
  and see what disappears - and the rule that fingerprints read and never write.

## 1.1.0 - 2026-09-08

Batch preparation, workshop boards, and a second panel - plus a way for the
board to work out which panel it has rather than being told.

### Added

- **`scripts/detect-panel.sh`** - identify the connected panel over ssh or adb,
  or select one by hand with `--select <id>`. DSI carries no EDID, so the
  fingerprint is taken from the touch or power controller on the carrier's I2C
  bus. It works with **no overlay loaded at all**, which is the case that
  matters: verified on a board set to `display=none`, where the Goodix
  controller still returned its product ID and the address the other panel uses
  correctly NAKed. `--scan` dumps the bus for a panel nobody has described yet.
- `DETECT_ADDR` / `DETECT_WRITE` / `DETECT_READ` / `DETECT_EXPECT` /
  `DETECT_NOTE` in `.panel` files, so adding a detectable panel stays a
  one-file job. A panel without them is still installable by name.
- Support for the **official Arduino 5inch-DSI-TOUCH-A**, which needs nothing
  from this repository except selecting it: `STOCK_SUPPORT=1` takes the short
  path through `scripts/15-select-stock-panel.sh`, building nothing and
  overwriting nothing.
- `tools/prepare-board.sh` - one command per board over USB: password
  bootstrap, clock, OS update, drivers, DKMS, overlay and display. Needs no
  network on the board; the host lends its own through `adb reverse`.
- `tools/usb-proxy.py`, which is how that works - useful on guest Wi-Fi behind
  a captive portal, where a headless board has no way through.
- `scripts/50-autologin.sh` - boot straight to the desktop, no login prompt.
  Meant for workshop and demo boards; reversible with `--disable`.

### Fixed

- **`prepare-board.sh` would have damaged boards destined for the official
  panel.** It assumed the Waveshare definition and always generated an overlay
  into Arduino's 5-inch display slot. On that hardware the result is no DRM
  connector at all. It now honours `--panel`, takes the stock path when the
  definition asks for it, and accepts `--panel auto` to ask the board.
- The installer printed a row of blank timing fields for a stock panel, and
  demanded `curl` on a path that fetches nothing.
- The CI guard against stray control characters **was itself written using
  literal control characters**, making it the file most likely to be silently
  disabled by an editor that normalises them. It is a Python check now, and it
  covers `tools/` and `panels/` as well.

## 1.0.0 — 2026-09-03

First tagged release. Panel and touchscreen work on a vanilla Arduino UNO Q
with the UNO Media Carrier, on any of the three kernel lines Arduino ships.

### The bug this release is really about

On cold boots, writes to the panel controller's `REG_PORTC` fail 50–90% of the
time. That alone is survivable — but **retrying them wedges the entire CCI I²C
bus for ~85 seconds**, and the dark panel and missing touchscreen were both
collateral damage from that, not separate faults.

Measured: with the driver blacklisted a boot shows **zero** CCI timeouts and
every device answering from 8 s; loading it drives that to 87 on demand.

### Added

- `panel-simple` gains a descriptor for the panel (mainline has no generic
  `panel-dsi` binding).
- `edt-ft5x06` polls instead of requiring an IRQ the carrier does not wire,
  splits the 33–63 byte read that Qualcomm's CCI cannot do, and retries
  identification instead of giving up on the first `-ETIMEDOUT`.
- `rpi-panel-attiny-regulator` built from source; write results are checked,
  and a lost backlight write is repaired **inside the driver** by re-asserting
  `REG_PWM` until it sticks.
- Recovery service as a backstop, and a device-tree overlay generator driven by
  `.panel` files.
- **DKMS registration**, so a kernel upgrade rebuilds the modules instead of
  leaving a black screen with no explanation.
- `update.sh` for existing installs.
- `bench/` — a camera-based reliability benchmark, because **no software check
  can see this failure**: DRM reports a connected connector scanning out a
  framebuffer while the screen is dark.
- CI running `install-matrix.py` weekly, which catches a kernel bump breaking
  the patch anchors before a user does.

### Fixed

- `PORTC` is written once and never retried. An earlier version of these
  patches retried ~13 times, turning a handful of failures into a 100+ write
  storm aimed at the one operation that wedges the bus. The touch identify
  retry no longer pulses the reset line, which is itself a `PORTC` write.

### Measured

Cold boots, counting only boots that actually hit the bug:

| | panel ends up dark | panel works |
| --- | --- | --- |
| without these fixes | **5** | 0 |
| with them | **0** | **7** |

Fisher exact two-tailed p = 0.0013. Touch binds at 12 s on the first probe,
where it used to fail and be reloaded at 99 s.

### Known limitations

- **One boot in eight is still unexplained.** The driver re-asserted `REG_PWM`,
  the write succeeded, and the panel stayed dark. Two mechanisms were proposed
  and both were tested and disproved; `bench/RESULTS.md` says "unknown" rather
  than inventing a third.
- The recovery service cannot be removed yet: touch still needs a post-boot
  reload after a bad boot.
- Validated on **one board, one kernel, one panel**. The patches *apply* on
  `qcom-v6.16.7` and `qcom-v6.19.0` but have not been compiled or run there,
  and `panels/TEMPLATE.panel` has never been exercised on other hardware.

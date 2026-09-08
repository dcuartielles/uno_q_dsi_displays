# Changelog

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

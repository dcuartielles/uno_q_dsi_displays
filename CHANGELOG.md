# Changelog

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

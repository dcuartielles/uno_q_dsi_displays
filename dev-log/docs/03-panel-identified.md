# Step 3 — Panel identified empirically (2026-09-01)

We tested the official 5-inch overlay against the real hardware. It failed, and the
failure identified the panel precisely. Branch B is confirmed.

## The experiment

```sh
arduino-linux-config carrier enable media-carrier display=5-dsi-touch-a
# -> "Incompatible overlays, removing [qrb2210-arduino-imola-video_sound-usbc.dtbo]"
sudo reboot
```

The tool's own message confirms the architecture we deduced from the schematics: the
panel overlay and the USB-C DisplayPort overlay are **mutually exclusive**, because
the QRB2210 has a single DSI controller.

## The result: total display failure

`/sys/class/drm/` contained only `version` — no `card0`, no connectors at all.

```
waveshare-regulator 0-0045: error -ETIMEDOUT: Failed to program GPIOs
waveshare-regulator 0-0045: probe with driver waveshare-regulator failed with error -110
anx7625 3-0058: *ERROR* fail to get internal panel.
mipi-dsi 5e94000.dsi.0: deferred probe pending: supplier regulator-panel-iovcc not ready
platform regulator-panel-vcc:  deferred probe pending: supplier 0-0045 not ready
platform regulator-panel-iovcc: deferred probe pending: supplier 0-0045 not ready
```

Failure chain: the driver for the Waveshare controller at 0x45 times out → the panel
regulators never come up → the DSI panel defers forever → the DPU never binds → no
DRM device whatsoever. Worth noting for later: **a failed panel probe takes the whole
display subsystem down with it, not just the panel.**

## The I2C scan that settles it

Bus 0 is the media carrier's DSI-side bus (`Qualcomm-CCI`):

```
20: -- -- -- -- -- -- UU -- ...      0x26  pca9555, carrier GPIO expander (bound)
30: -- ... 38 -- ...                 0x38  PRESENT, unclaimed
40: -- -- -- -- -- 45 -- ...         0x45  PRESENT, unclaimed
50: (nothing)                        0x5d  ABSENT
```

- **0x5d absent** → no GT9271, so this is definitively *not* a 5-DSI-TOUCH-A.
- **0x45 + 0x38 present** → the Raspberry Pi 7" official-display clone signature:
  ATTINY power/backlight controller at 0x45, FocalTech FT5406-class touch at 0x38.

The chip at 0x45 acknowledges its address (so `i2cdetect` sees it) but does not speak
the Waveshare touch-a register protocol, which is exactly why the driver got
`-ETIMEDOUT` rather than `-ENXIO`.

**Conclusion: the panel is the 800×480 `5inch DSI LCD` / `(B)`, TC358762 family —
as originally identified. It is physically connected and electrically alive.**

Incidentally this also settles the cable question from README section 1: the panel is
plugged into the 22-pin carrier socket and responds, so no 15→22-pin adapter is needed.

## What we need to build

Checked against kernel 7.0.0-g122c2c22d838:

| driver | role | status |
| --- | --- | --- |
| `tc358762` | DSI→DPI bridge | **ABSENT** — build out-of-tree |
| `rpi-panel-attiny-regulator` | panel power + backlight @0x45 | **ABSENT** — build out-of-tree |
| `panel-simple` | the 800×480 panel timings | present |
| `edt-ft5x06` | FocalTech touch @0x38 | present |

Both missing drivers are mainline, so this is a compile job, not a porting job.
`linux-headers-7.0.0-g122c2c22d838` is available from `apt-repo.arduino.cc`.

## Current board state

Reverted to a working display path and verified:

```
arduino-linux-config carrier enable media-carrier display=none
# card0, card0-DP-1 back; carrier stays enabled
```

## Next steps

1. `apt-get install linux-headers-7.0.0-g122c2c22d838` plus build-essential.
2. Obtain the two mainline sources matching 7.0:
   `drivers/gpu/drm/bridge/tc358762.c` and
   `drivers/regulator/rpi-panel-attiny-regulator.c`; build them out-of-tree.
3. Write a custom overlay modelled on
   `qrb2210-arduino-imola-carrier-media-panel-5in_touch_a-dsi.dtbo` (decompile it with
   `dtc -I dtb -O dts`), replacing the waveshare/himax/goodix nodes with:
   - `raspberrypi,7inch-touchscreen-panel-regulator` @ 0x45
   - `toshiba,tc358762` bridge on the DSI host, **`data-lanes = <0 1>`** (the panel is
     2-lane; the official overlays use 4)
   - a DPI panel node with the 800×480 timings
   - `edt,edt-ft5406` (or `edt-ft5x06`) touch @ 0x38
4. Decide how to install it. `arduino-linux-config` reads overlays from
   `/boot/efi/dtb/qcom/`; check whether dropping a `.dtbo` there makes it appear as a
   new `display=` option, or whether we compose manually with `fdtoverlay` and
   overwrite `qrb2210-arduino-imola.dtb` (the firmware loads that file by name — there
   is no `devicetree` line in the loader entries).
5. Verify with `modetest -M msm -c`, then `kmscube`, then `evtest` for touch.

## Safety note that now matters more

`bootctl set-oneshot` does not work here (EFI vars are read-only), and a bad panel
overlay kills the entire DRM device. The recovery path is **ADB over USB-C**, which
survived every failure in this session, plus `arduino-linux-config carrier enable
media-carrier display=none` to get back to a known-good state.

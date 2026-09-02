# Step 6 — Reaching parity with Raspberry Pi's software stack

Prompted by a good challenge: *"have you checked against the RPi code used to drive
the 5 inch panel?"* I had not. Doing so found four real defects. This documents the
comparison method and the findings, which are useful independently of whether this
particular panel ever works.

## How to compare our software against RPi's

Three layers, each compared differently. Skipping any of them hides bugs.

| Layer | RPi's artefact | Ours | Method |
| --- | --- | --- | --- |
| 1. Device tree | `vc4-kms-dsi-7inch-overlay.dts` + `edt-ft5406.dtsi` | our `.dts` | decompile both, compare node structure, properties, phandle wiring |
| 2. Driver source | `raspberrypi/linux` downstream `.c` | mainline `.c` from `arduino/linux-qcom` | **`diff` the files** |
| 3. Runtime | — | the board | `pr_info` instrumentation, `dmesg`, register readback |

The DSI host cannot be made identical — RPi uses `vc4`, we use Qualcomm `msm`.

Fetch both sides for layer 2 with:

```sh
RPI=https://raw.githubusercontent.com/raspberrypi/linux/rpi-6.12.y
MLN=https://raw.githubusercontent.com/arduino/linux-qcom/122c2c22d838   # our kernel's commit
for f in drivers/regulator/rpi-panel-attiny-regulator.c \
         drivers/gpu/drm/bridge/tc358762.c \
         drivers/input/touchscreen/edt-ft5x06.c; do
    curl -fsSL "$RPI/$f" -o "rpi/$(basename $f)"
    curl -fsSL "$MLN/$f" -o "mainline/$(basename $f)"
done
diff -u rpi/tc358762.c mainline/tc358762.c
```

**The trap:** assuming mainline and vendor implement the same hardware identically.
They do not. Mainline drivers are often *cleaned up* versions that dropped
vendor-specific behaviour the hardware actually needs.

## What the comparison found

### Layer 1 — device tree (3 defects in our v1 overlay)

| | RPi | our v1 | fixed in |
| --- | --- | --- | --- |
| bridge reset | intermediate `reg_bridge` regulator whose *enable GPIO* is ATTINY gpio 0, `vin-supply = <&reg_display>` | `reset-gpios` directly on the tc358762 | v2 |
| `vddc-supply` | `<&reg_bridge>` | `<&attiny>` | v2 |
| h-front porch | **131** | **1** | v2 |
| pixel clock | 30 MHz | 25.98 MHz | v2 |
| hbp / vbp | 45 / 22 | 46 / 21 | v2 |
| touch | `edt,edt-ft5506`, `vcc-supply`, `reset-gpio = <&reg_display 1 1>` | `edt-ft5406`, neither | v2 |

The reset ordering mattered most: RPi releases the bridge reset *as part of regulator
enable*, before the bridge driver's `pre_enable` runs. Ours did it inside
`pre_enable` — which is exactly where the fragile I2C write kept failing.

The timings came from the wrong source: `panel-raspberrypi-touchscreen.c` (the legacy
combined driver) rather than the `tc358762 + panel-simple` path this panel uses.

### Layer 2 — driver source (the big one)

**`tc358762.c` — mainline never programs the bridge's output timing.**

```c
/* RPi has these; mainline does NOT */
#define LCD_HS_HBP 0x0424 / LCD_HDISP_HFP 0x0428
#define LCD_VS_VBP 0x042c / LCD_VDISP_VFP 0x0430

tc358762_write(ctx, LCD_HS_HBP, (mode.hsync_end - mode.hsync_start) |
               ((mode.htotal - mode.hsync_end) << 16));
...
```

Mainline has `struct drm_display_mode mode` *and* the `mode_set` callback that fills
it — then never uses it. The bridge drives its DPI output with default timings.

**`tc358762.c` — init runs at a different point.** RPi calls `tc358762_init()` from
`atomic_pre_enable` (before the video stream starts); mainline moved it to
`atomic_enable` (after). The bridge's setup registers are DSI low-power command
writes, so issuing them mid-stream is a plausible source of DSI PHY errors.

**`rpi-panel-attiny-regulator.c` — `is_enabled` regressed.**

```c
/* RPi  */ return state->port_states[REG_PORTC - REG_PORTA] & PC_RST_BRIDGE_N;
/* main */ regmap_read(rdev->regmap, REG_PORTC, &data); return data & PC_RST_BRIDGE_N;
```

Mainline reads the chip. On this panel PORTC always reads `0x10`, so `is_enabled`
reports **false** even when the regulator is on — the source of the
`tc358762-power: disabled` reading that misled the whole investigation.

**`edt-ft5x06.c` — mainline dropped polling.** RPi added
`FIRST_POLL_DELAY_MS 300`, `POLL_INTERVAL_MS 17` and `edt_ft5x06_ts_irq_poll_timer()`
for hosts with no touch interrupt — exactly our case, since the Media Carrier's DSI
connector has pins 17/18 as `NC`. Mainline requires an IRQ and fails
`request_irq(0) ... -EINVAL`. **Not yet backported.**

### Layer 3 — runtime instrumentation

`attiny_set_port_state()` ignores every `regmap_write()` return code. Adding logging
revealed silent failures:

```
WRITE reg=0x83 val=0x01 ret=-110   <- PC_LED_EN never asserted
WRITE reg=0x83 val=0x0d ret=-110   <- bridge/LCD reset never released
```

A retry loop with `msleep(50)` between attempts fixed those.

## Patches applied (all on the board, sources in ~/panel-build)

1. `tc358762.c`: add `LCD_*` timing register writes from `ctx->mode`
2. `tc358762.c`: call `tc358762_init()` from `pre_enable`, not `atomic_enable`
3. `rpi-panel-attiny-regulator.c`: `is_enabled` uses the cached port state
4. `rpi-panel-attiny-regulator.c`: retry port and backlight writes

Originals kept as `*.c.orig`. Result: every I2C write succeeds on a healthy boot,
`bridge_reg` and `tc358762-power` both report `enabled`, and the bridge is programmed
with RPi's exact mode:

```
tc358762-dbg: init mode 800x480 clk=30000 hs=931-933 ht=978 vs=487-489 vt=511 flags=0xa
tc358762-dbg: init from PRE_ENABLE ret=0
```

## Still not working, and what the evidence says

The panel remains dark, and the digitiser only partially functions.

**The I2C link to this panel is intermittent.** Two consecutive boots:

```
boot A:  CCI timeouts   2   all attiny writes ret=0, attempts 1-3
boot B:  CCI timeouts 666   every write ret=-110, attempts=61, bring-up took 117s
```

Worse, the failures correlate with a specific event:

```
 8.197  WRITE 0x82=0x80  ret=0     ok    <- PB_LCD_MAIN: panel power ON
17.804  WRITE 0x83=0x01  ret=-110  FAIL  <- everything after this fails
```

Writes succeed until the panel's main power rail is switched on, then fail.

**Touch tells the same story.** The FT5x06 answers its ID registers correctly
(`0xA3=0x54 0xA6=0x0b 0xA8=0x79`) and produced exactly one coherent report — a press
and then a lift-off at (346, 327) — before freezing. Over 3919 subsequent polls the
registers never changed once.

Both chips on the panel are alive enough to answer I2C, and neither functions properly
once the panel is meant to be running. The same carrier, kernel and I2C bus drive a
Waveshare 8-DSI-TOUCH-A flawlessly with working multitouch.

**The one measurement not yet taken:** 3.3 V at the panel's FPC pin 14/15 during boot,
watching for a dip around the 8-second mark when `PB_LCD_MAIN` is written. That
separates "panel not adequately powered" from "panel faulty" and needs a meter, not
more code.

## Useful for testing without the kernel driver

The Qualcomm CCI adapter *does* support combined transactions (`i2cdetect -F` reports
`I2C: yes`), but the FT5x06 needs a repeated-START block read — per-register SMBus
reads return `ENXIO` on the data registers. `i2ctransfer` does it correctly:

```sh
i2ctransfer -f -y 0 w1@0x38 0x00 r8
#  0x00 0x00 0x01 0x01 0x5a 0x01 0x47 0x00
#              TD=1  ^XH   ^XL   ^YH   ^YL   -> press, X=346, Y=327
```

Decode: `0x02` low nibble = contacts; `0x03` bits 7-6 = event (0 down, 1 up),
bits 3-0 = X high; `0x04` = X low; `0x05` bits 7-4 = id, bits 3-0 = Y high;
`0x06` = Y low.

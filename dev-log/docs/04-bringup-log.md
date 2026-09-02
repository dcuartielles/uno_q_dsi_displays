# Step 4 — Panel bring-up log (2026-09-01)

## Where we got to

The **entire software stack is built, installed and running**. The DRM pipeline comes
up completely and correctly with our panel's exact timings. What is not yet confirmed
is whether the panel physically lights.

### Built and installed

Two mainline drivers absent from kernel 7.0, compiled on-device from Arduino's own
kernel fork at the exact commit our kernel was built from (`122c2c22d838`):

```
/lib/modules/7.0.0-g122c2c22d838/extra/tc358762.ko
/lib/modules/7.0.0-g122c2c22d838/extra/rpi-panel-attiny-regulator.ko
```

Autoloaded via `/etc/modules-load.d/panel-tc358762.conf`. Build env:
`linux-headers-7.0.0-g122c2c22d838` + build-essential; gcc 14.2; no signing lockdown.

### The overlay

`dt/uno-q-waveshare-5in-800x480-tc358762.dts` — compiled with `dtc -@` and installed
**in place of** Arduino's 5-inch overlay, because `arduino-linux-config` hardcodes its
option names and `.dtbo` filenames inside the Go binary (verified with `strings`):

```
/boot/efi/dtb/qcom/qrb2210-arduino-imola-carrier-media-panel-5in_touch_a-dsi.dtbo
/boot/efi/dtb/qcom/qrb2210-arduino-imola-carrier-media-panel-5in_touch_a-dsi.dtbo.orig  <- Arduino's original
```

Then composed with the official tool, which also drops the USB-C DP overlay:

```sh
arduino-linux-config carrier enable media-carrier display=5-dsi-touch-a
# Incompatible overlays, removing [qrb2210-arduino-imola-video_sound-usbc.dtbo]
```

### Result — the pipeline is fully alive

```
card0-DPI-1 => connected          800x480, 109x65 mm
modetest: 800 801 803 849 / 480 487 489 510 @ 25979 kHz, nhsync nvsync, preferred
crtc[47]: crtc-0  enable=1 active=1  plane_mask=1 connector_mask=1
plane[35]: fb=50 800x480 XR24, allocated by Xorg
[drm] fb0: msmdrmfb frame buffer device
/sys/class/backlight/0-0045  max=255 brightness=255 bl_power=0
gpiochip3 [7inch-touchscreen-p] (2 lines)
```

Those are exactly the timings we put in the DTS. A full modeset happened and a
framebuffer is being scanned out.

## Two real bugs found and fixed along the way

1. **Bridge held in reset.** `attiny_lcd_power_enable()` ends with
   `PORTC = PC_LED_EN`, leaving `RST_BRIDGE_N` low — enabling the regulator does
   *not* release the bridge. Reset release is a separate GPIO on the same chip
   (gpio 0 = `RST_BRIDGE_N`, gpio 1 = `RST_TP_N`). Fixed by adding
   `reset-gpios = <&attiny 0 0>` to the bridge node; `tc358762_pre_enable()` does
   `gpiod_set_value(reset, 1)`, so ACTIVE_HIGH.

2. **Lane count.** The bridge is **1-lane**, not 2 and not 4:
   ```
   tc358762.c:279  dsi->lanes = 1;
   tc358762_init() DSI_LANEENABLE = LANEENABLE_L0EN | LANEENABLE_CLEN
   ```
   Arduino's official overlays use `<0 1 2 3>`. Ours is now `data-lanes = <0>`.

## Outstanding

Nothing visible on the panel yet.

### Ruled out

- **I2C bus health** — the PCA9555 at 0x26 on the same CCI bus works perfectly
  (all 15 carrier LEDs toggle). 30 s of backlight writes produced **zero** new
  `i2c-qcom-cci ... timeout` messages.
- **Panel controller dead** — it answers reads consistently (`REG_ID = 0xc3`,
  ATTINY firmware ver 2; `PORTB = 0x85`; `PORTC = 0x10`).
- **Wrong panel family** — 0x45 + 0x38 present, 0x5d absent: RPi-7"-clone confirmed.
- **Modeset / timings** — verified live via `modetest` and the atomic state dump.

### Still suspect

- `tc358762-power: state=disabled`. Probably a **false reading**:
  `attiny_lcd_power_is_enabled()` does `regmap_read(REG_PORTC) & PC_RST_BRIDGE_N`,
  but port readback on this chip is unreliable — the driver otherwise caches port
  state in software (`state->port_states[]`) precisely because of that. `REG_PWM`
  and `REG_POWERON` both read back `0xff` regardless of what is written, which
  confirms readback is meaningless here.
- 26 `i2c-qcom-cci: master 0 queue 0 timeout` messages during boot (7.9–12.1 s),
  causing `failed to enable backlight: -110` at panel-enable time. None since.
  The CCI power domain (`gcc_camss_top`) is runtime-suspended and resumes on
  demand — a plausible cause of *boot-time-only* flakiness.
- `panel-simple panel-dpi: Specify missing bus_format` / `bpc = 0`. Cosmetic-looking,
  but with `bus_format = 0` the bridge chain has no negotiated pixel format. Worth
  fixing next.
- `dsi_err_worker: status=4` on every boot.

### FINAL CONCLUSION (2026-09-01, end of session)

Every software avenue is exhausted and the fault is isolated to the panel's own
controller. The decisive evidence, in order:

**1. Panel power is fine.** The touch controller at 0x38 - a separate chip with its
own supply - returns live firmware values (`0xA3=0x54`, `0xA6=0x0b`, `0xA8=0x79`).

**2. The driver's I2C writes were failing, and we fixed that.** Instrumenting
`rpi-panel-attiny-regulator` (the stock driver ignores every `regmap_write()` return
code) revealed the two writes that matter were timing out:

```
WRITE port reg=0x83 val=0x01 ret=-110   <- PC_LED_EN never asserted
WRITE port reg=0x83 val=0x0d ret=-110   <- bridge/LCD reset never released
BACKLIGHT brightness=255 ret=-110 attempts=11
```

Adding retries with `msleep(50)` between attempts fixed it completely:

```
WRITE port reg=0x83 val=0x01 ret=0 attempts=1
WRITE port reg=0x83 val=0x0d ret=0 attempts=1
BACKLIGHT brightness=255 ret=0 attempts=1
```

No more `-110`, `tc358762-power: enabled`, `card0-DPI-1 connected` at 800x480,
0 DSI errors. **Panel still completely dark.**

**3. And here is why: the chip at 0x45 ACKs writes but does not store them.**

```
REG    WROTE   READS BACK
0x81   0x04    0xff      mismatch
0x82   0x80    0x85      mismatch
0x83   0x0d    0x10      mismatch
```

Verified with both the combined (`i2cget`) and the split write/delay/read protocol
the driver itself uses - identical results. Only 0x80/0x82/0x83 are readable at all,
always the same three fixed values, regardless of what is written.

**The device at 0x45 does not implement the Raspberry Pi ATTINY register map.**
That is why neither driver can enable the backlight:

| driver | outcome |
| --- | --- |
| `rpi-panel-attiny-regulator` | probes, writes now all succeed at the bus level, chip ignores them |
| `gpio-waveshare-dsi` (Arduino's overlay) | probes, registers a 16-line gpiochip and a backlight, then `regulator-panel-avdd: GPIO setup failed -110/-ENXIO`, blocking the whole DSI chain |

Since the backlight is driven purely by I2C to this controller - nothing to do with
DSI, the bridge, or the device tree - a dark backlight cannot be explained by
anything left on the Arduino side. Either the panel expects a third protocol we
have not identified, or it is faulty. Without another host to cross-check the panel
(no Raspberry Pi available), those two cannot be separated.

**Recommended:** a Waveshare `5-DSI-TOUCH-A` (or 8/10-inch equivalent) is supported
out of the box - `arduino-linux-config carrier enable media-carrier
display=5-dsi-touch-a` and reboot. All the tooling, build environment and overlay
method built here transfer directly.

---

### Earlier analysis (kept for the reasoning trail)

The 5 V theory below is incorrect and is kept only to show the reasoning. Per
Waveshare's own wiki for this exact panel, it is powered from the DSI connector at
**3.3 V** (FPC pins **14 and 15 are both 3V3**), draws ~1.2 W, and there is no 5 V
input anywhere on it. Waveshare also specify `dtoverlay=vc4-kms-dsi-7inch`, i.e. the
Raspberry Pi 7" display overlay, confirming the ATTINY + TC358762 architecture.

**Panel power is proven healthy.** The touch controller at 0x38 - a separate chip
with its own supply - reads back live firmware values:

```
0xA3 = 0x54 (chip id)   0xA6 = 0x0b (fw ver)   0xA8 = 0x79 (vendor)   0xA9 = 0x01
```

A running MCU with real firmware. So the rail is fine and power is off the table.

**The real fault: the controller at 0x45 accepts reads but not writes.**

```
full register dump of 0x45:
80: c3 ff 85 10 ff ff ff ff ...        (everything else 0xff)
after the driver writes brightness 255 -> 0:
>>> IDENTICAL - not one byte changed
```

Only three registers are readable, they never change, and writes are variously
ACKed-and-discarded, `-ETIMEDOUT` (-110), or `-ENXIO` (-6). Reads are reliable
throughout (40/40 correct), and the PCA9555 at 0x26 on the same CCI bus works
perfectly, so the bus itself is healthy.

**Both candidate drivers fail at exactly the same point** - writing state to 0x45:

| overlay | driver at 0x45 | result |
| --- | --- | --- |
| ours | `rpi-panel-attiny-regulator` | probes, regulator reports `enabled`, but no register ever changes; panel dark |
| Arduino's `5in_touch_a` | `gpio-waveshare-dsi` | probes on good power (`gpiochip3 [dsi-touch-gpio]`, 16 lines) and registers a backlight, but `regulator-panel-avdd: setup of GPIO failed: -110 / -ENXIO`, which blocks the entire DSI chain (`mipi-dsi: deferred probe pending: supplier regulator-panel-avdd not ready`) - no DRM device at all |

So the panel's controller does not reliably accept writes over the Media Carrier's
DSI-side I2C, which is the **Qualcomm CCI** master (a camera-oriented controller)
running in the **1.8 V** domain, whereas the panel is a 3.3 V Raspberry Pi
peripheral. Reads succeed because a slave pulling the line low is unambiguous;
writes are where it breaks down. This is consistent across two independent drivers
and is not something a device tree change can fix.

Also notable: Waveshare document the touch as **Goodix at 0x14**; the bus shows
**0x38** and no 0x14/0x5d, and when Arduino's overlay declared a Goodix at 0x5d it
failed with `I2C communication failure: -6`.

**Board left in our overlay's state** - `card0-DPI-1 connected`, correct 800x480
timings, framebuffer scanning out, backlight device present, panel dark.

---

### (SUPERSEDED, INCORRECT) earlier conclusion: the DSI connector carries no 5 V

From Arduino's official full pinout (`ASX00083-full-pinout.pdf`, "Advanced Section"),
the DISPLAY connector is:

```
DISPLAY (DSI0, 22-pin)
 22  OUT  +3V3        <-- the ONLY power pin on the whole connector
 21  CCI_I2C_SDA0
 20  CCI_I2C_SCL0
 19  GND
 18  NC
 17  NC               <-- CAMERA0/1 have CSI0_POWER_EN here; DISPLAY does not
 16  GND
 15  MIPI_DSI0_L3_P      14  MIPI_DSI0_L3_M
 13  GND
 12  MIPI_DSI0_L2_P      11  MIPI_DSI0_L2_M
 10  GND
  9  MIPI_DSI0_CLK_P      8  MIPI_DSI0_CLK_M
  7  GND
  6  MIPI_DSI0_L1_P       5  MIPI_DSI0_L1_M
  4  GND
  3  MIPI_DSI0_L0_P       2  MIPI_DSI0_L0_M
  1  GND
```

Our panel is the Raspberry Pi 7"-clone design:

- its **ATTINY controller runs on 3.3 V** -> powers up, answers `REG_ID = 0xc3`,
  accepts 40/40 I2C writes, and lets the regulator report `enabled`;
- its **LCD panel and LED backlight boost converter need 5 V** -> never arrives,
  so the backlight cannot light and the panel cannot display, no matter what the
  software does.

This is why the officially supported Waveshare `*-DSI-TOUCH-A` panels work: they are
designed for the Raspberry Pi 5 / CM4 22-pin connector, which likewise offers only
3V3, so they run entirely from it. The older 800x480 RPi-7"-clone expects 5 V
supplied separately - on a Raspberry Pi that is done with two jumper wires from the
GPIO header to the display board.

**The carrier does provide 5 V, on its power header:**

```
Power header:  1 = +3V3 OUT   2 = +5V OUT   3 = VIN IN (7-24 V)   4 = GND
```

**Fix:** run two wires from that header's **pin 2 (+5V)** and **pin 4 (GND)** to the
panel's 5 V / GND input, exactly as the official RPi 7" display is wired to a Pi.
Keep the FPC connected for DSI + I2C. Do not inject 5 V into DSI pin 22 - the carrier
actively drives 3V3 there.

Everything below documents the diagnosis that led here.

### Earlier finding: insufficient supply current (real, but not the whole story)

Repowering the UNO Q from a **5 V / 3 A charger** instead of a PC USB port changed
the measurable state immediately:

| | PC USB port | 5 V / 3 A charger |
| --- | --- | --- |
| `tc358762-power` regulator | `disabled` | **`enabled`** |
| CCI I2C timeouts per boot | 26 | **1** |
| `failed to enable backlight: -110` | present | **gone** |

So the ATTINY could never actually bring up the panel rails on a PC port's ~0.5-0.9 A.
Everything below was written while that was still the open question.

Confirmed by the user: the panel stays completely dark through a 40 s backlight
blink, with every I2C write acknowledged and zero bus timeouts.

The carrier datasheet (ASX00083, §6.2 Power Considerations) says:

> "The UNO Media Carrier is powered mainly through the JMEDIA and JMISC connectors
> from the host board. An optional **7-24 V DC VIN input (J13)** is available for
> additional power when using power-hungry peripherals such as multiple cameras or
> **high-power displays**."
>
> "Both UNO Q and VENTUNO Q support 7-24 V DC via VIN input. UNO Q can alternatively
> be powered via **5 V DC / 3 A USB-C**."

The board is currently powered from a **PC USB port** (~0.5-0.9 A), not a 3 A supply.
That fits every observation: the ATTINY controller draws microamps and is perfectly
alive on I2C, but the panel's main rail and backlight need hundreds of milliamps and
never come up - so register writes are ACKed while nothing physically actuates, and
port readback never changes.

Note the datasheet also never claims the DSI connector sources display power; the
DSI0 entry only says *"Operates at 1.8 V logic level, routed from JMEDIA connector."*

**Action:** repower from a 5 V / 3 A USB-C supply, or feed 7-24 V DC into the
carrier's VIN (J13), then retest.

### SSH lifeline (so power can be changed freely)

ADB needs the USB-C cable connected to the PC, which conflicts with using that port
for power. Key-based SSH was therefore set up over Wi-Fi:

```
board   <BOARD-IP>   user arduino
key     <scratchpad>/unoq_key      (ed25519, no passphrase)
helper  scripts/ssh-board.ps1 "command"
```

`sshd` was enabled with the NOPASSWD sudoers rules (`systemctl enable/start ssh`),
so this needed no password. Verified working.

### Key open question

**Does the panel backlight physically glow?** That single observation splits the
remaining problem cleanly:

- glows, no image  -> power and I2C are fine; the TC358762 is not emitting pixels
                      (reset timing, DSI init writes failing, or bus format)
- never glows      -> the panel's main power rail is not coming up, despite the
                      controller answering on I2C

## Reverting

```sh
# back to the stock USB-C DisplayPort path
arduino-linux-config carrier enable media-carrier display=none
sudo reboot

# restore Arduino's original 5-inch overlay
D=/boot/efi/dtb/qcom
sudo cp $D/qrb2210-arduino-imola-carrier-media-panel-5in_touch_a-dsi.dtbo.orig \
        $D/qrb2210-arduino-imola-carrier-media-panel-5in_touch_a-dsi.dtbo
```

## Touch (deferred)

`edt_ft5x06 0-0038: request_irq(0) ... Unable to request touchscreen IRQ (-22)`.
The driver requires a real interrupt line and our DT provides none; the RPi handles
this panel's touch by polling through firmware, which has no equivalent here. Options:
find whether the touch INT is routed to a PCA9555 or SoC GPIO on the carrier, or patch
the driver for polled operation. Deferred until the display itself is confirmed.

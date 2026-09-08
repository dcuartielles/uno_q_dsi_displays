# Adding a new panel

The single most useful fact in this repository:

> **Raspberry Pi has already done the hard work for most of these panels.**

Their kernel tree describes a dozen or more DSI panels, and the numbers
transfer directly to the UNO Q. Finding the right file usually takes longer
than the port itself.

---

## 1. Find your panel in the Raspberry Pi tree

Browse:

<https://github.com/raspberrypi/linux/tree/rpi-6.12.y/arch/arm/boot/dts/overlays>

Look for `vc4-kms-dsi-*-overlay.dts`. At the time of writing:

```
vc4-kms-dsi-7inch-overlay.dts                 official Pi 7" (TC358762 bridge)
vc4-kms-dsi-waveshare-800x480-overlay.dts     Waveshare 800x480   <- our panel
vc4-kms-dsi-waveshare-panel-overlay.dts       Waveshare DSI-TOUCH series
vc4-kms-dsi-waveshare-panel-v2-overlay.dts    newer Waveshare series
vc4-kms-dsi-ili9881-5inch-overlay.dts         ILI9881 5"
vc4-kms-dsi-ili9881-7inch-overlay.dts         ILI9881 7"
vc4-kms-dsi-ili79600-10-1inch-overlay.dts     ILI79600 10.1"
vc4-kms-dsi-generic-overlay.dts               generic template
vc4-kms-dsi-lt070me05000-overlay.dts          JDI LT070ME05000
cutiepi-panel-overlay.dts                     CutiePi
```

Also check the vendor's own wiki for which `dtoverlay=` line they tell Pi users
to add — that names the file. **Treat it as a hint, not gospel**: Waveshare's
wiki for our panel says `vc4-kms-dsi-7inch`, which is the *Pi 7"* overlay and
describes a different bridge chip entirely. The panel actually matched
`vc4-kms-dsi-waveshare-800x480`. Trust the silkscreen on the board over the
documentation.

## 2. Get the timings

The overlay contains either a `panel-timing` block you can copy directly:

```dts
panel-timing {
    clock-frequency = <27777000>;
    hactive = <800>;      vactive = <480>;
    hfront-porch = <59>;  hsync-len = <2>;  hback-porch = <45>;
    vfront-porch = <7>;   vsync-len = <2>;  vback-porch = <22>;
};
```

…or a `compatible` like `"waveshare,7.9inch-dsi"`, in which case the numbers are
in `drivers/gpu/drm/panel/panel-simple.c`. Search for that string, follow it to
a `drm_display_mode`, and convert:

```
CLOCK_KHZ = .clock
HFRONT    = .hsync_start - .hdisplay
HSYNC     = .hsync_end   - .hsync_start
HBACK     = .htotal      - .hsync_end
VFRONT    = .vsync_start - .vdisplay
VSYNC     = .vsync_end   - .vsync_start
VBACK     = .vtotal      - .vsync_end
```

Worked example, the Pi 7" panel:

```c
.clock = 30000,
.hdisplay = 800,  .hsync_start = 800 + 131,
.hsync_end = 800 + 131 + 2,  .htotal = 800 + 131 + 2 + 45,
.vdisplay = 480,  .vsync_start = 480 + 7,
.vsync_end = 480 + 7 + 2,    .vtotal = 480 + 7 + 2 + 22,
```

gives `CLOCK_KHZ=30000  HFRONT=131  HSYNC=2  HBACK=45  VFRONT=7  VSYNC=2  VBACK=22`.

**Do not borrow timings from a similar panel.** Our 800×480 needs 27.777 MHz and
`hfront-porch 59`; the Pi 7" — same resolution — needs 30 MHz and 131. Using the
wrong one gives a perfectly healthy-looking pipeline and a blank screen.

## 3. Lane count, format, mode flags

From the overlay's panel endpoint:

```dts
port { endpoint { data-lanes = <1>; }; };     ->  DSI_LANES=1
dsi-color-format = "RGB888";                  ->  DSI_FORMAT="MIPI_DSI_FMT_RGB888"
mode = "MODE_VIDEO";                          ->  DSI_MODE_FLAGS="MIPI_DSI_MODE_VIDEO"
```

If the panel has a `panel_desc_dsi` in `panel-simple.c` instead, read `.lanes`,
`.format`, `.flags` and `.bpc` straight off it.

## 4. Bridge or no bridge?

**Most of these panels need no bridge node.** They carry a self-configuring
DSI-to-RGB bridge (Chipone ICN6211 and friends) that needs no host programming
— the panel attaches directly to the DSI host and you just feed it video. That
is what the generated overlay does.

The exception is the **Toshiba TC358762**, used by the official Pi 7" display,
which *does* need host configuration. If your panel has one, look at
`vc4-kms-dsi-7inch-overlay.dts`; it needs a bridge node and an extra driver, and
this repository's generator does not emit that. See
[HOW-IT-WORKS.md](HOW-IT-WORKS.md).

Read the silkscreen on the panel PCB. It is the fastest way to settle this and
it is what finally cracked our case.

## 5. Touch and the power controller

From the overlay's I²C fragment. The Pi-style ATTINY controller at `0x45`
handles panel power and backlight; touch is commonly `edt,edt-ft5506` at `0x38`
or `goodix,gt9271` at `0x5d`.

Confirm against your actual hardware before trusting the overlay:

```bash
sudo i2cdetect -y -r 0        # try each bus; CCI is the carrier's DSI-side bus
```

Our panel showed `0x26` (carrier expander), `0x38` (touch) and `0x45`
(controller), with **nothing at `0x5d`** — which is how we knew it was not one
of the Goodix-based DSI-TOUCH panels.

## 6. Write the definition and install

```bash
cp panels/TEMPLATE.panel panels/my-panel.panel
$EDITOR panels/my-panel.panel
sudo ./install.sh panels/my-panel.panel
sudo reboot
sudo ./scripts/40-verify.sh panels/your-panel.panel
sudo ./scripts/test-display.sh
```

## 7. If the image is wrong rather than absent

That is good news — the panel is being driven and only the numbers are off.

| symptom | try |
| --- | --- |
| rolling / tearing | pixel clock wrong: adjust `CLOCK_KHZ` |
| shifted horizontally | `HFRONT` / `HBACK` |
| shifted vertically | `VFRONT` / `VBACK` |
| torn on the right, repeats | `HACTIVE` or lane count |
| wrong colours | `DSI_FORMAT` (RGB888 vs RGB666) |
| garbled at high refresh | try `MIPI_DSI_MODE_VIDEO_BURST` |

Edit the `.panel` file and re-run `install.sh`; it rebuilds and reinstalls.

## 8. Make it detectable

Once the panel works, teach `scripts/detect-panel.sh` to recognise it, so the
next person does not have to know which panel they are holding.

You do not need to understand I2C to do this. The short version: find an
address that answers only when your panel is plugged in, write it into your
`.panel` file, check that detection still picks the right panel. The rest of
this section is that, slowly.

### What is being detected, and why not the display

DSI panels have no EDID — the thing a monitor uses to tell a computer what it
is. There is genuinely nothing to ask the display. What these panels *do* carry
is a touch or power controller sitting on the carrier's I2C bus, and those
differ between panels. So that is the fingerprint: not the screen, the little
chip next to it.

### Step 1 — see what is on the bus

Connect the panel, then:

```
$ sudo ./scripts/detect-panel.sh --scan

==> Carrier I2C bus is i2c-0
  UU means a driver has already claimed that address - it is still there.

       0  1  2  3  4  5  6  7  8  9  a  b  c  d  e  f
  00:                         -- -- -- -- -- -- -- --
  10: -- -- -- -- -- -- -- -- -- -- -- -- -- -- -- --
  20: -- -- -- -- -- -- UU -- -- -- -- -- -- -- -- --
  30: -- -- -- -- -- -- -- -- -- -- -- -- -- -- -- --
  40: -- -- -- -- -- 45 -- -- -- -- -- -- -- -- -- --
  50: -- -- -- -- -- -- -- -- -- -- -- -- -- 5d -- --
  60: -- -- -- -- -- -- -- -- -- -- -- -- -- -- -- --
  70: -- -- -- -- -- -- -- --

==> Addresses that answer a read
  0x26  ->  0xf5
  0x45  ->  0x01
  0x5d  ->  0x10
```

Three chips answered. `0x26` is on the carrier itself and is there with no
panel at all, so it is no use. That leaves `0x45` and `0x5d`.

**Run the scan again with the panel unplugged.** Whatever disappears belongs to
the panel, and that is your candidate. It is the single most useful minute you
can spend here, and it costs nothing.

### Step 2 — write the simplest fingerprint that could work

If your candidate address is not used by any other panel in `panels/`, you are
already done. Presence alone is enough:

```sh
DETECT_ADDR="0x5d"
DETECT_NOTE="touch controller at 0x5d, only this panel has one"
```

That is a complete, working fingerprint. Skip to step 4.

### Step 3 — only if the address is shared

Sometimes two panels answer at the same address with different chips behind it.
Both panels shipped here occupy `0x45`, so for them the address proves nothing
and the *contents* have to do the work.

Most controllers have an ID register holding something recognisable. Where is
it? Two places to look, in order:

1. **The datasheet**, under a heading like "Product ID" or "Chip ID".
2. **The Linux driver** for that chip, which has to do exactly what you are
   doing. Search the kernel tree for the chip name and look for a `#define`
   with `ID` in it — `goodix_ts` reads `GOODIX_REG_ID`, which is `0x8140`.

Then read it by hand before committing to anything. `i2ctransfer` takes
"write these bytes, then read this many":

```
$ sudo i2ctransfer -y -f 0 w2@0x5d 0x81 0x40 r4
0x39 0x31 0x31 0x00
        ^ write 2 bytes to 0x5d: the register address 0x8140, high byte first
                          ^ then read 4 bytes back
```

`0x39 0x31 0x31` is ASCII for `911` — a Goodix GT911 saying its own name. Turn
that into:

```sh
DETECT_ADDR="0x5d"                # the address that identifies this panel
DETECT_WRITE="0x81 0x40"          # register to address first; omit to read directly
DETECT_READ="4"                   # bytes to read back (default 1)
DETECT_EXPECT="0x39 0x31 0x31"    # expected start of the reply
DETECT_NOTE="Goodix GT911 touch controller reports product ID 911"
```

`DETECT_EXPECT` matches the *start* of the reply, so trailing bytes you do not
care about can be left out. If a chip legitimately reports more than one ID,
separate them with `|` — `DETECT_EXPECT="0xc3|0xde"`.

### Step 4 — check it, twice

**Does it still pick the right panel?** Run detection and read the output. Every
panel is tried, and you want exactly one `ok`:

```
$ sudo ./scripts/detect-panel.sh
==> Looking for a known panel on i2c-0
  ok  arduino-5in-touch-a: 0x5d replied 0x39 0x31 0x31 0x00
  waveshare-800x480: 0x45 replied 0x01, wanted 0xc3|0xde
```

If two panels match, the tool refuses to guess and tells you so. Make
`DETECT_EXPECT` stricter.

**Does it answer on an unconfigured board?** This is the case detection exists
for — a board out of the box, nothing installed, nobody yet knowing what is
plugged into it. Some controllers are held in reset until a driver releases
them and stay silent until then, which makes them useless as a fingerprint
precisely when you need one. The Waveshare panel's FT5x06 at `0x38` is one of
these, which is why its fingerprint reads the ATTINY at `0x45` instead.

To test, take the overlay away and look again:

```bash
sudo arduino-linux-config carrier enable media-carrier display=none
sudo reboot
# once it is back
sudo ./scripts/detect-panel.sh
# then put it back
sudo ./scripts/detect-panel.sh --apply
sudo reboot
```

### One rule: fingerprints read, they never write

Writes to the RPi-style ATTINY — `REG_PORTC` above all — can wedge the whole
CCI bus for well over a minute, and that is the root cause of the dark-panel
bug this repository exists to fix (see
[Cold boots: known behaviour](../README.md#cold-boots-known-behaviour)).

`DETECT_WRITE` is for the register address you want to read *from*, and nothing
else. Never use it to configure, reset, or wake a chip.

### If you cannot find a clean signature

Leave the `DETECT_` block out. Nothing breaks. The panel is installed by name
instead, which is a perfectly normal way to use this:

```bash
sudo ./scripts/detect-panel.sh --select my-panel
```

`--list` will show it as needing manual selection, and `--select` touches no
I2C at all, so it works with the panel unplugged.

Please open a PR with any panel you get working — a `.panel` file is a small
contribution that saves the next person a long evening.

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

Please open a PR with any panel you get working — a `.panel` file is a small
contribution that saves the next person a long evening.

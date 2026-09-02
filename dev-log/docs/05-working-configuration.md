# WORKING — Arduino UNO Q + UNO Media Carrier + Waveshare 8-DSI-TOUCH-A

Status: **display and multitouch both working**, 2026-09-01.

## The configuration

```
board     Arduino UNO Q (qrb2210 "imola") + UNO Media Carrier
panel     Waveshare 8-DSI-TOUCH-A  (800x1280 portrait, 10-pt touch)
OS        Debian 13 trixie, kernel 7.0.0-g122c2c22d838
power     5 V / 3 A USB-C to the board, PLUS the panel's own 5 V/GND lead
```

## Verified state

```
carrier:      display = 8-dsi-touch-a
connector:    card0-DSI-1 => connected
mode:         800x1280
framebuffer:  msmdrmfb 800x1280 @32bpp  (/dev/fb0)
backlight:    /sys/class/backlight/0-0045  max=255 cur=255
touch:        Goodix-TS 0-005d: ID 9271, version 1070
              input: "Goodix Capacitive TouchScreen" -> /dev/input/event2
              669 events captured in a 15 s drag test, full multitouch
i2c bus 0:    0x26 UU (pca9555)   0x45 UU (waveshare)   0x5d UU (goodix)
drivers:      panel_jadard_jd9365da_h3, gpio_waveshare_dsi, goodix_ts
```

All three drivers are **in-tree** in kernel 7.0. Nothing had to be built.

## How to reproduce from scratch

1. Update the OS — a launch-era image has no media-carrier overlays at all.
   See [02-update.md](02-update.md). Short version: connect Wi-Fi, let the clock
   sync, `apt-get update`, `apt-get full-upgrade`, then
   `apt-get install arduino-unoq` (pulls kernel 7.0 + `arduino-linux-config`).
   Watch for the `alsa-ucm-conf` conflict documented there.
2. Wire the panel:
   - 22-pin DSI ribbon to the carrier's **DSI0** connector (B1) — *not* either
     CSI camera connector, which are physically identical.
   - The panel's **5 V / GND lead is mandatory**: Waveshare specify >= 0.8 A and
     the panel is *not* powered over the DSI cable. Take it from the carrier's
     power header (**pin 2 = +5V, pin 4 = GND**), the same way it would come off a
     Raspberry Pi's GPIO header. Power the board off before wiring.
3. Select the display and reboot:

```sh
arduino-linux-config carrier enable media-carrier display=8-dsi-touch-a
sudo reboot
```

That is the entire software procedure for a supported panel.

## Known cosmetic messages (harmless)

```
anx7625 3-0058: *ERROR* fail to get internal panel / fail to parse DT : -19
```
Expected. The QRB2210 has one DSI controller; enabling the panel takes it away
from the ANX7625 USB-C DisplayPort bridge, which then has nothing to attach to.
`arduino-linux-config` says as much when enabling: *"Incompatible overlays,
removing [...video_sound-usbc.dtbo]"*. **USB-C DisplayPort output and the DSI
panel are mutually exclusive.**

```
Goodix-TS 0-005d: Error reading 186 bytes from 0x8047: -95
Goodix-TS 0-005d: Invalid config (0, 0, 10), using defaults
Goodix-TS 0-005d: Error reading 10 bytes from 0x814e: -5   (occasional)
```
The config read fails and the driver falls back to defaults; touch works fine.
The occasional `-5` reads are the same class of intermittent CCI I2C hiccup
documented in [04-bringup-log.md](04-bringup-log.md). Not currently causing
visible problems, but worth remembering if touch ever glitches.

## Leftovers from the 5-inch effort (harmless, removable)

- `tc358762.ko` and `rpi-panel-attiny-regulator.ko` in
  `/lib/modules/7.0.0-g122c2c22d838/extra/`, autoloaded via
  `/etc/modules-load.d/panel-tc358762.conf`. They load but bind to nothing.
  To remove: `sudo rm /etc/modules-load.d/panel-tc358762.conf`
  (note `rpi-panel-attiny-regulator.ko` is the **patched** build with the
  write-retry fix, which is worth keeping around — see below).
- Our 800x480 overlay is preserved at
  `/boot/efi/dtb/qcom/qrb2210-arduino-imola-carrier-media-panel-5in_touch_a-dsi.dtbo.ours`;
  Arduino's original is back in the live slot.

## A real bug found along the way, worth reporting upstream

`drivers/regulator/rpi-panel-attiny-regulator.c` — `attiny_set_port_state()`
ignores the return value of `regmap_write()` entirely. On a host whose I2C
occasionally NAKs, the writes that assert `PC_LED_EN` and release the
bridge/LCD resets can fail silently, and the panel simply never lights with no
diagnostic whatsoever. Instrumenting it produced:

```
WRITE port reg=0x83 val=0x01 ret=-110   <- PC_LED_EN never asserted
WRITE port reg=0x83 val=0x0d ret=-110   <- bridge/LCD reset never released
```

Adding a retry loop with `msleep(50)` between attempts made every write succeed.
The patched source is at `~/panel-build/rpi-panel-attiny-regulator.c` on the
board (original at `.c.orig`).

## Next steps

- **Rotation** — the panel is natively portrait (800x1280). For landscape, rotate
  in the compositor/X, and rotate touch to match.
- **What to run on it** — Arduino App Lab, a Wayland compositor, or a direct-KMS
  app. `lightdm` is already running and allocating framebuffers.
- **Backlight** — `echo N | sudo tee /sys/class/backlight/0-0045/brightness` (0-255).

# MIPI DSI panels on the Arduino UNO Q

Drive a **MIPI DSI touchscreen** from an **Arduino UNO Q** through the **UNO Media
Carrier**, including panels Arduino does not officially support.

Arduino ships support for three Waveshare displays — the `5`, `8` and
`10.1-DSI-TOUCH-A`. If you have one of those, you don't need this repository:
enable it in App Lab, or run

```bash
sudo arduino-linux-config carrier enable media-carrier display=8-dsi-touch-a
```

This repository is for **everything else**. It was built while getting a
Waveshare **800×480 DSI LCD** working, and it generalises: describe your panel
in a small text file and the scripts generate the kernel descriptor and the
device-tree overlay for you.

**Verified working:** Waveshare 800×480 DSI LCD (4.3"/5", ICN6211) — display and
multitouch, on kernel 7.0.0, Debian 13.

---

## Before you start

**A 5 V / 3 A power supply is not optional.** A PC USB port supplies roughly
0.5–0.9 A. On that, the panel controller's I²C writes fail intermittently, the
backlight never enables and the display silently never appears. Symptoms look
like a software fault and will waste your evening. Arduino documents 5 V/3 A for
the carrier; believe them.

You also need:

- Arduino UNO Q + UNO Media Carrier
- a MIPI DSI panel and the right FPC cable — the carrier's connector is
  **22-pin**; 15-pin panels need a 15→22 adapter cable
- network access on the board (Wi-Fi is fine)
- shell access — SSH or ADB

Two things worth knowing up front:

- **Enabling a DSI panel disables DisplayPort over USB-C.** The SoC has one DSI
  controller and both cannot use it. `arduino-linux-config` says so when you
  enable the display.
- **We reuse Arduino's 5-inch display slot.** `arduino-linux-config` hardcodes
  its option names and `.dtbo` filenames internally, so a new option cannot be
  registered. Our overlay goes into the 5-inch slot and is selected as
  `display=5-dsi-touch-a`. Arduino's original is backed up and restored by
  `uninstall.sh`. If you own a real 5-DSI-TOUCH-A, uninstall first.

---

## Quick start

```bash
git clone https://github.com/<you>/uno-q-dsi-panel.git
cd uno-q-dsi-panel

# 1. connect the panel with the board POWERED OFF, then power up
# 2. install (updates the OS first if the board is on an old image)
sudo ./install.sh panels/waveshare-800x480.panel
sudo reboot

# 3. check
sudo ./scripts/40-verify.sh panels/waveshare-800x480.panel
sudo ./scripts/test-display.sh
sudo ./scripts/test-touch.sh
```

If your panel isn't in `panels/`, see **[docs/ADDING-A-PANEL.md](docs/ADDING-A-PANEL.md)** —
it's usually a ten-minute job, because Raspberry Pi already describes most of
these panels and we can lift the numbers.

---

## Step by step

### 1. Update the OS

**Skip nothing here if your board is from 2025.** The UNO Q shipped in October
2025; Media Carrier support arrived in March 2026. A launch-era image has **no
carrier device-tree overlays at all** and no `arduino-linux-config`. Check:

```bash
ls /boot/efi/dtb/qcom/ | grep carrier-media
```

Nothing? Then run:

```bash
sudo ./scripts/10-update-os.sh
sudo reboot
```

`install.sh` does this automatically if needed. It handles two traps:

- **The clock.** The UNO Q has no RTC battery. Before NTP syncs, every repo
  fails with `Not live until <date>` signature errors and `apt-repo.arduino.cc`
  fails TLS. It looks like a broken mirror; it's just the date. The script
  waits for sync.
- **`alsa-ucm-conf`.** A blanket `full-upgrade` moves Arduino's vendor-pinned
  packages onto generic Debian ones, and `arduino-unoq` then won't install
  because an apt pin prefers a backports `alsa-ucm-conf` needing an
  uninstallable `libasound2t64`. The script pins Arduino's build explicitly.

No reflash is needed — the new kernel comes from `apt`.

### 2. Describe your panel

`panels/*.panel` is a small shell-syntax file:

```sh
PANEL_ID="waveshare-800x480"
PANEL_COMPATIBLE="waveshare,4-3-inch-dsi"
PANEL_C_NAME="waveshare_800x480"

CLOCK_KHZ=27777
HACTIVE=800;  HFRONT=59;  HSYNC=2;  HBACK=45
VACTIVE=480;  VFRONT=7;   VSYNC=2;  VBACK=22

DSI_LANES=1
DSI_FORMAT="MIPI_DSI_FMT_RGB888"
DSI_MODE_FLAGS="MIPI_DSI_MODE_VIDEO"
BPC=8

PANEL_CTRL_COMPATIBLE="raspberrypi,7inch-touchscreen-panel-regulator"
PANEL_CTRL_ADDR="0x45"
TOUCH_COMPATIBLE="edt,edt-ft5506"
TOUCH_ADDR="0x38"
```

### 3. Install

```bash
sudo ./install.sh panels/your-panel.panel
sudo reboot
```

This builds three kernel modules and installs one overlay. Details in
**[docs/HOW-IT-WORKS.md](docs/HOW-IT-WORKS.md)**.

### 4. Verify

```bash
sudo ./scripts/40-verify.sh panels/waveshare-800x480.panel
```

A working board reports a connected DRM connector, a mode, `/dev/fb0`, a
backlight, **zero DSI errors**, and a touch input device.

---

## Cold boots: known behaviour

**Short version: it works, and on about half of cold boots the panel lights
immediately; on the rest it is black for ~40 seconds and then comes up.**

The cause is narrow. Writes to one register on the panel controller
(`REG_PORTC`) fail 50-90% of the time on this hardware. When the lost write is
the one enabling the backlight, the panel stays dark - the picture is being
rendered correctly the whole time, it simply is not lit. `install.sh` handles
both halves:

- the **driver patch** stops a single failed write cascading into a bus-wide
  outage (retrying `PORTC` used to wedge the whole I2C bus for ~85 seconds,
  which also killed the touchscreen)
- a **recovery service** re-asserts the backlight when the enable write was one
  of the ones lost

Measured over cold boots, counting only the boots that actually hit the bug:

| | panel ends up dark | panel works |
| --- | --- | --- |
| without either fix | **5** | 0 |
| with both (this repo) | **0** | **7** |

Of those 7: **4 lit at boot with no help**, 3 were dark and repaired at ~38 s.
Fisher exact two-tailed p = 0.0013. Touch also improved independently - it now
binds at 12 s on the first probe, where it used to fail and be reloaded at 99 s.

**This is not a cure.** The underlying `PORTC` write failures are untouched and
unexplained; we stopped amplifying them and we repair the one consequence that
matters. The properly correct fix is a deferred `REG_PWM` re-assert inside the
driver, which would remove the userspace service and light the panel in seconds
rather than 38.

Full method, per-boot records and camera evidence - including why no software
check can see this failure at all - are in [bench/RESULTS.md](bench/RESULTS.md),
and the plan for the real fix is in [docs/BUG-STRATEGY.md](docs/BUG-STRATEGY.md).

---

## What gets changed

| Change | Where | Reverted by |
| --- | --- | --- |
| `panel-simple.ko` replaced (adds your panel) | `/lib/modules/$(uname -r)/kernel/.../panel/` | `uninstall.sh` |
| `edt-ft5x06.ko` replaced (polling + short reads) | `/lib/modules/$(uname -r)/kernel/.../touchscreen/` | `uninstall.sh` |
| `rpi-panel-attiny-regulator.ko` added | `/lib/modules/$(uname -r)/extra/` | `uninstall.sh` |
| overlay installed in the 5-inch slot | `/boot/efi/dtb/qcom/` | `uninstall.sh` |
| carrier display enabled | `arduino-linux-config` | `uninstall.sh` |
| `uno-q-dsi-panel-recover.service` added | `/etc/systemd/system/` | `uninstall.sh` |

Stock modules are kept as `*.ko.distrib`, Arduino's overlay as
`*.dtbo.arduino-orig`. To undo everything:

```bash
sudo ./uninstall.sh && sudo reboot
```

**Kernel upgrades wipe this.** The modules are built for one kernel version and
the composed DTB is regenerated on upgrade. After any kernel update, re-run
`sudo ./install.sh panels/your-panel.panel`.

---

## Repository layout

```
install.sh / uninstall.sh     one-shot install and full revert
panels/*.panel                panel definitions (TEMPLATE.panel to start)
scripts/10-update-os.sh       vanilla/old image -> kernel with carrier support
scripts/20-build-drivers.sh   fetch, patch and install the kernel modules
scripts/30-install-overlay.sh generate, compile and enable the overlay
scripts/35-install-recovery.sh boot-recovery service for flaky-I2C boots
scripts/40-verify.sh          post-reboot checks
scripts/test-display.sh       colour bars on the panel
scripts/test-touch.sh         report touch events
tools/                        generators and kernel-source patchers
bench/                        reliability benchmark (camera + cold boots)
docs/                         adding a panel, how it works, troubleshooting
dev-log/                      the original investigation, warts and all
```

`dev-log/` is the unedited record of getting the first panel working, including
the wrong turns. It is not needed to use this repository, but it documents how
the conclusions were reached — see
[docs/HOW-IT-WORKS.md](docs/HOW-IT-WORKS.md) for the distilled version.

---

## Credit and licence

The hard information here comes from the **Raspberry Pi kernel tree**, which
describes most of these panels already. Several fixes are backports of theirs.

The kernel patches are derived from Linux sources and are GPL-2.0. The scripts
and documentation are MIT. See `LICENSE`.

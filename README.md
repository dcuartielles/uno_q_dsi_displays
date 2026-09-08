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
# 2. let the board work out which panel it is, and install it
#    (updates the OS first if the board is on an old image)
sudo ./scripts/detect-panel.sh --apply
sudo reboot

# 3. check
sudo ./scripts/40-verify.sh panels/<the panel it found>.panel
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

## Which panel do you have?

Ask the board:

```bash
sudo ./scripts/detect-panel.sh
```

DSI panels carry no EDID, so nothing announces itself the way a monitor does.
What they do have is a touch or power controller on the carrier's I2C bus, and
those differ per panel — so that is what gets fingerprinted. It works on a
board that has never been configured, with `display=none` and no overlay
loaded: the Goodix controller on the Arduino panel still answers with its
product ID at that point, which is exactly when you need to know what is
plugged in.

Add `--apply` and it installs what it found. If you already know which panel
you have, skip detection entirely:

```bash
./scripts/detect-panel.sh --list                        # what is supported
sudo ./scripts/detect-panel.sh --select arduino-5in-touch-a
```

`--select` never touches I2C, so it works with the panel unplugged — useful
when preparing boards in a batch before the displays arrive.

Both work over ssh or adb, since the script simply runs on the board:

```bash
ssh arduino@<board> 'cd uno-q-dsi-panel && sudo ./scripts/detect-panel.sh --apply'

adb -s <serial> shell 'cd ~/uno-q-dsi-panel && sudo ./scripts/detect-panel.sh --apply'
```

If nothing is recognised, `--scan` dumps every address that answers. Turning
that into a fingerprint your panel is recognised by is a walkthrough of its own,
written for people who have never touched I2C — see
**[Make it detectable](docs/ADDING-A-PANEL.md#8-make-it-detectable)**.

### The two panels, and why they need opposite treatment

| | Arduino **5inch-DSI-TOUCH-A** | Waveshare 800x480 (4.3" and 5") |
| --- | --- | --- |
| panel driver | `panel-himax-hx8394` **stock** | `panel-simple` **patched** |
| DSI lanes | 4 | 1 |
| resolution | 720x1280 portrait | 800x480 landscape |
| backlight | `gpio-waveshare-dsi` **stock** | `rpi-panel-attiny-regulator` **built + patched** |
| touch | `goodix_ts` @ 0x5d **stock** | `edt-ft5x06` @ 0x38 **patched** |
| what to run | `sudo ./install.sh panels/arduino-5in-touch-a.panel` | `sudo ./install.sh panels/waveshare-800x480.panel` |

The Waveshare entry covers both the 4.3" and the 5" variants with one
definition. They are the same panel electrically - same timings, same bridge,
same controllers - and nothing on the I2C bus tells them apart, so one
definition is the only correct answer rather than a shortcut. Both are verified
on hardware.

**The official Arduino panel needs nothing from this repository except
selecting it.** Arduino ships the overlay and the kernel already has every
driver, so the installer checks they are present, makes sure Arduino's own
overlay is in place, and enables the display. It builds and patches nothing.

That check matters, because installing a *described* panel like the Waveshare
writes a generated overlay into Arduino's 5-inch display slot. Do that on a
board destined for the official panel and it comes up with **no DRM connector
at all** - the overlay describes one DSI lane, an attiny at 0x45 and a touch
controller at 0x38, none of which are on that hardware. Selecting the official
panel restores Arduino's overlay automatically and keeps the displaced one
alongside it.

---

## Preparing several boards over USB

If you have a batch to bring up to date - no Media Carrier, no panel, and no
usable Wi-Fi - one command per board does the lot:

```bash
tools/prepare-board.sh                       # the attached board
tools/prepare-board.sh --serial 247242846    # pick one of several
tools/update-progress.sh --watch             # follow the OS update
```

About 25 minutes for a launch-era board, mostly unattended, and it is
idempotent: run it again on a half-finished board and it skips what is already
done, so an interrupted run costs nothing.

**On the host you need:** `adb`, `python3`, and a `~/.unoq-secrets.txt`
containing `SUDO_PASS=<the password you want on these boards>`. Nothing needs
to be installed on the board first.

What it does, in order:

1. **Sets the account password.** A factory board has none - `passwd -S` reports
   `NP` and the account is flagged expired, so `sudo` fails with a message
   about token manipulation that says nothing about the real cause.
2. **Sets the clock** from the host. There is no RTC battery, so a board off
   the shelf can be months behind, and every apt repository then fails
   signature verification with `Not live until <date>` - which reads like a
   broken mirror.
3. **Opens a network tunnel over USB** and points apt at it.
4. **Updates Debian and installs `arduino-unoq`**, which brings the newer
   kernel, the Media Carrier overlays and `arduino-linux-config`. Reboots, then
   re-establishes the tunnel and the clock, both of which are lost across it.
5. **Builds the patched drivers and registers them with DKMS**, so a future
   kernel upgrade rebuilds them instead of silently leaving a black screen.
6. **Installs the panel overlay and enables the display**, so the board is
   finished rather than needing a second pass once hardware is attached.

Afterwards, with a Media Carrier and panel connected:

```bash
sudo ./scripts/40-verify.sh panels/<your-panel>.panel
```

**No network needed on the board.** It lends the host's connection over USB
(`tools/usb-proxy.py` plus `adb reverse`), which works on guest Wi-Fi behind a
captive portal, on a corporate network, or anywhere the board itself cannot
authenticate. Nothing is bypassed: the traffic is the host's own already
authenticated connection.

Three things it handles that catch people out by hand:

- **A fresh board has no password at all.** `passwd -S` reports `NP` and the
  account is flagged expired, so `sudo` fails with a message about token
  manipulation that says nothing about the real cause.
- **The clock is wrong.** There is no RTC battery, so every apt repository
  fails signature verification with `Not live until <date>` - which reads like
  a broken mirror. The host's clock is copied over, and again after the reboot.
- **The USB tunnel does not survive a reboot**, and forgetting to re-establish
  it looks like a network fault rather than a missing tunnel.

It installs the overlay and enables the display too, so the board is
**finished**: attach a Media Carrier and panel later and it comes up, with no
second pass. Pass `--no-display` if you would rather keep DisplayPort over
USB-C on a particular board, since the SoC has one DSI controller and the two
cannot share it.

### Workshop mode

A room full of boards that each stop at a login prompt wastes the first ten
minutes of a session:

```bash
tools/prepare-board.sh --autologin           # boot straight to the desktop
tools/prepare-board.sh --autologin-console   # and on tty1 as well
```

or on a board that is already set up:

```bash
sudo ./scripts/50-autologin.sh               # enable
sudo ./scripts/50-autologin.sh --status
sudo ./scripts/50-autologin.sh --disable     # put the login screen back
```

**This removes a login prompt**, so anyone at the screen gets the desktop -
sensible for workshop and demo boards, not for anything on a network you care
about. It writes a lightdm drop-in rather than editing `lightdm.conf`, so a
package upgrade cannot silently take the setting with it, and `--disable`
restores things exactly.

---

## Cold boots: known behaviour

**Short version: it works. On most cold boots the panel lights normally; on
the rest it is black for about four seconds and then comes up.**

The cause is narrow. Writes to one register on the panel controller
(`REG_PORTC`) fail 50-90% of the time on this hardware. When the lost write is
the one enabling the backlight, the panel stays dark - the picture is being
rendered correctly the whole time, it simply is not lit. `install.sh` handles
both halves:

- the **driver patch** stops a single failed write cascading into a bus-wide
  outage (retrying `PORTC` used to wedge the whole I2C bus for ~85 seconds,
  which also killed the touchscreen)
- the **driver repairs itself**: when the backlight write is lost it re-asserts
  `REG_PWM` - the one register that never fails - until it sticks, typically
  about four seconds later
- the **touch driver waits the bus out** instead of failing: when the bus is
  busy, probe succeeds anyway and bring-up retries from a work item, holding
  nothing in between. Measured over 32 warm reboots, the touchscreen survived
  0 of 11 wedged boots before this and 5 of 5 after (p = 0.00023) - see
  [bench/results/touch/](bench/results/touch/README.md)
- a **recovery service** remains, because the backlight has no such
  self-rescue. It re-asserts the backlight after lost controller writes, and
  reloads the touch driver only as a backstop

Measured over cold boots, counting only the boots that actually hit the bug:

| | panel ends up dark | panel works |
| --- | --- | --- |
| without either fix | **5** | 0 |
| with both (this repo) | **1** | **14** |

Fisher exact two-tailed p = 0.00039. Touch improved independently: it binds at
12 s on the first probe, where it used to fail and be reloaded at 99 s.

The one remaining failure is **not explained**: the driver re-asserted the
backlight, the write succeeded, and the panel stayed dark anyway. Two
mechanisms were proposed and both were tested and disproved - see
[bench/RESULTS.md](bench/RESULTS.md).

Over 8 cold boots with the in-driver repair, **every** repair was done in the
kernel - the userspace service contributed nothing to the backlight on any of
them.

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
| DKMS registration, so kernel upgrades rebuild | `/usr/src/uno-q-dsi-panel-*` | `uninstall.sh` |

Stock modules are kept as `*.ko.distrib`, Arduino's overlay as
`*.dtbo.arduino-orig`. To undo everything:

```bash
sudo ./uninstall.sh && sudo reboot
```

**Kernel upgrades are handled.** The modules are registered with DKMS, so they
are rebuilt automatically when a new kernel is installed - and if a future
kernel changes a driver API the rebuild fails visibly at upgrade time rather
than leaving you with a black screen at the next boot. If that happens, re-run
`sudo ./update.sh`, which fetches and patches sources matching the new kernel.

---

## Repository layout

```
install.sh / uninstall.sh     one-shot install and full revert
update.sh                     bring an existing install up to date
VERSION / CHANGELOG.md        what you are running, and what changed
panels/*.panel                panel definitions (TEMPLATE.panel to start)
scripts/detect-panel.sh       identify the connected panel, or pick one by hand
scripts/10-update-os.sh       vanilla/old image -> kernel with carrier support
scripts/15-select-stock-panel.sh  select a panel the kernel already supports
scripts/20-build-drivers.sh   fetch, patch and install the kernel modules
scripts/25-install-dkms.sh    register with DKMS so kernel upgrades rebuild
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

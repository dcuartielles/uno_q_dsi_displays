# Troubleshooting

Work down this list in order — the early entries are far more common than the
late ones.

---

## Nothing on the panel at all, not even a backlight glow

**Check power first.** A PC USB port is not enough. With a starved supply the
panel controller's I²C writes fail intermittently, the backlight never enables,
and everything in software looks correct. Use a **5 V / 3 A** supply.

```bash
dmesg | grep -c 'cci.*timeout'
```

A healthy boot shows 0–2. Hundreds means the I²C link is struggling, which in
our experience always traced back to power or a marginal FPC cable.

**Check the cable and its orientation.** The carrier's connector is 22-pin;
15-pin panels need a 15→22 adapter. Contacts must face the right way at both
ends. Reseat both ends with the latches fully closed — we saw one cable produce
hundreds of I²C timeouts and another none.

**Do not plug the panel into a camera connector.** The CSI and DSI connectors
are physically identical and electrically different.

---

## Backlight glows dimly but there is no image

Many of these panels have a deliberately visible minimum brightness, so a dim
glow means only that the panel has power. Check whether the pipeline is up:

```bash
sudo ./scripts/40-verify.sh panels/your-panel.panel
```

If the connector is `connected`, a mode is listed and `/dev/fb0` exists, the
host side is fine and the problem is the panel description — most often the
wrong bridge assumption or wrong timings. See
[ADDING-A-PANEL.md](ADDING-A-PANEL.md) §4 and §7.

---

## No DRM connector, no `/dev/fb0`

```bash
dmesg | grep -iE 'panel|dsi|deferred probe pending'
```

- `deferred probe pending: supplier regulator-… not ready` — the panel power
  controller did not probe. Usually the wrong controller for your panel, or
  power trouble.
- `-ETIMEDOUT` on GPIO setup — the controller at `0x45` is not responding as
  expected. Confirm what is actually on the bus:
  ```bash
  sudo i2cdetect -y -r 0     # try each bus
  ```
- Nothing about the panel at all — the compatible in your `.panel` file does not
  match the descriptor that was compiled in. Check:
  ```bash
  grep -i your-compatible /lib/modules/$(uname -r)/modules.alias
  ```

---

## The image is garbled, rolling, shifted or torn

Good news: the panel *is* being driven, and only the numbers are wrong. See the
table in [ADDING-A-PANEL.md](ADDING-A-PANEL.md) §7. Edit the `.panel` file and
re-run `install.sh`.

---

## The panel is black for the first minute after a cold boot

**Expected, and it repairs itself.** Measured on this hardware: on roughly 3
cold boots in 4, the panel controller's writes fail during boot and the
backlight PWM never gets set. The picture is being rendered correctly the whole
time - the screen just is not lit.

`uno-q-dsi-panel-recover.service` waits for the controller to answer over I2C
and then re-asserts the backlight. On a measured bad boot that happened at
**63 seconds**. Check what it did:

```bash
journalctl -u uno-q-dsi-panel-recover -b
```

A rescued boot looks like:

```
panel controller writes FAILED during boot - the screen is probably dark
re-asserted backlight 0-0045 (brightness 255)
```

If the panel is still black well after that, the backlight is not the problem -
work through the entries below.

Measured effect, bad boots only (see [../bench/RESULTS.md](../bench/RESULTS.md)):

| | panel dark | panel working |
| --- | --- | --- |
| without the service | 5 | 0 |
| with the service | 0 | 6 |

---

## It works on some boots and not others

This one is real, and it is the reason `install.sh` also installs a recovery
service. On some boots the Qualcomm **CCI** I²C bus is dead for the first
minute or so — every transfer to the panel controller at `0x45` and the touch
controller at `0x38` times out:

```
attiny: write reg=0x83 val=0x00 failed after 49 tries: -110
i2c-qcom-cci 5c1b000.cci: master 0 queue 0 timeout      (x565)
edt_ft5x06 0-0038: touchscreen probe failed after 2 tries: -110
```

On other boots of the **exact same image** there are two timeouts in total and
everything comes up. Count them:

```bash
dmesg | grep -c 'cci.*timeout'
```

A healthy boot shows 0–2. Hundreds means you hit the bad case.

The drivers bind perfectly if simply asked again once the bus has settled, so
`uno-q-dsi-panel-recover.service` waits for boot to finish, checks whether the
panel and touchscreen actually came up, and reloads the touch driver if not:

```bash
journalctl -u uno-q-dsi-panel-recover
sudo /usr/local/libexec/uno-q-dsi-panel-recover   # or run it by hand
```

Tune how long it keeps trying in `/etc/default/uno-q-dsi-panel`
(`RECOVER_BUDGET_SECONDS`).

**The display cannot be recovered this way.** The panel controller is a
separate MCU that keeps its state across a warm reboot, so a bad boot usually
still shows a picture — but from a *cold* start a bad boot can leave the panel
dark. Power-cycle and try again. Better power makes the bad case rarer, which
is the strongest hint that this is a supply/signal-integrity problem rather
than a software one.

---

## Touch does not work

```bash
sudo ./scripts/test-touch.sh
dmesg | grep -i edt_ft5
```

- `Unable to request touchscreen IRQ` / `error -22` — the polling patch is not
  in place. Re-run `install.sh`; make sure `TOUCH_ADDR` is set in your `.panel`.
- `Unable to fetch data, error: -6` — long I²C reads failing. The short-read
  patch handles this; if you see it, the patch did not apply.
- Input device exists but no events — check the touch controller is really at
  the address in your `.panel` file with `i2cdetect`. Ours is `0x38`; the
  DSI-TOUCH panels use `0x5d`.
- Axes inverted or swapped — set `TOUCH_INVERT_X` / `TOUCH_INVERT_Y` in the
  `.panel` file.

---

## It worked, then stopped after an update

**This should no longer happen.** The modules are registered with DKMS and are
rebuilt automatically when a new kernel is installed. Check:

```bash
dkms status uno-q-dsi-panel
```

If it lists your running kernel, the modules are in place. A kernel upgrade can
still replace the composed device tree in `/boot/efi/dtb/qcom/`, and a driver
API change will make the DKMS rebuild fail - loudly, at upgrade time. Either
way the fix is:

```bash
sudo ./update.sh
sudo reboot
```

`update.sh` re-fetches driver sources matching the new kernel, re-patches,
rebuilds, and reinstalls the overlay.

Pinning the kernel is no longer necessary now that DKMS rebuilds on
upgrade, but it is still a reasonable belt-and-braces step if you are
mid-project and want nothing to move:

```bash
sudo apt-mark hold linux-image-$(uname -r) linux-headers-$(uname -r)
```

---

## I lost access to the board

Enabling a DSI panel disables DisplayPort over USB-C, so a bad configuration can
leave you with no video. **ADB over USB-C keeps working** — it is plain USB data
and unaffected by the display pipeline:

```bash
adb devices
adb shell
```

Note the trade-off: ADB needs the USB-C port connected to a PC, which then also
powers the board from that port — and that is the starved-power case. For
recovery it is fine; for testing the display, use external power and SSH.

Once you have a shell:

```bash
sudo arduino-linux-config carrier enable media-carrier display=none
sudo reboot
```

`bootctl set-oneshot` does **not** work on this board — EFI variables are
read-only, so there is no "boot the old kernel once" escape hatch.

---

## Reporting a problem

Useful output to include:

```bash
uname -r
arduino-linux-config carrier show
sudo ./scripts/40-verify.sh panels/your-panel.panel
dmesg | grep -iE 'panel|dsi|drm|edt_ft5|attiny|cci' | tail -40
sudo i2cdetect -y -r 0
cat panels/your-panel.panel
```

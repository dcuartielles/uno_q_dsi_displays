# Step 2 — Update the OS *before* any device tree work

---

## What actually happened on this board (2026-09-01) — four non-obvious gotchas

Recorded because none of these are documented anywhere and all four cost time.

1. **The account had no password at all.** First setup was never completed, so
   `chage -l arduino` reported *"password must be changed"*. Every sudo attempt failed
   with *"Account or password is expired"* — which looks exactly like a wrong password,
   including when trying the documented factory default. Fix: Arduino ships a root
   helper `/usr/local/bin/arduino-passwd`, whitelisted NOPASSWD, that reads a new
   password on stdin and runs `chpasswd`. That is what the App Lab wizard uses.

2. **A lot needs no password at all.** The `arduino` user is in the `sysupgrade`
   group, and sudoers grants it NOPASSWD on exactly the update operations:
   `apt-get update`, `apt-get install --only-upgrade -y *`, `dpkg --configure -a`,
   `needrestart -r a`, `apt-get clean -y`. Wi-Fi needs no password either — plain
   `nmcli dev wifi connect` works for this user via polkit. So Wi-Fi and an index
   refresh are reachable before the password question is ever settled.

3. **The clock is wrong at boot and breaks apt.** There is no RTC battery
   (`RTC time: Thu 1970-01-01`). Before NTP syncs, every repository fails with
   *"Not live until <date>"* signature errors and `apt-repo.arduino.cc` fails TLS with
   *certificate verify failed*. It looks like a broken mirror or a proxy problem; it is
   just the date. `systemd-timesyncd` is enabled and fixes it within seconds of the
   network coming up — so **connect Wi-Fi, confirm `timedatectl` says synchronized,
   and only then run apt.**

4. **`arduino-app-cli system update` did nothing.** It exited 0 with
   *"Some indexes could not be updated"* and left all 232 stale packages in place. It
   only touches already-installed packages in any case, so it can never pull the new
   kernel. Use apt directly.

**And the payoff — what the update actually delivers.** The `arduino-unoq`
meta-package (not installed on launch images) depends on:

- `linux-image-7.0.0-g122c2c22d838` — kernel **7.0**, the tree the Imola DT was
  upstreamed into. This is what carries the media-carrier DTBs and `.dtbo` overlays.
- `arduino-linux-config` — *"a CLI interface for managing and applying device tree
  overlays for various media carrier boards"*. Official tooling for Phase 3.

Because it is a *new* package rather than an upgrade, the NOPASSWD rules cannot
install it — this is the one step that genuinely requires the account password.

---

This step is not optional housekeeping. It has to happen **before** we baseline the
system and long before we compose a DTB, for three reasons:

1. **The Media Carrier is new hardware (announced March 2026).** The overlays we plan
   to use as templates — `qrb2210-arduino-imola-carrier-media.dtbo` and
   `...-carrier-media-panel-8in_touch_a-dsi.dtbo` — only exist in images built after
   carrier support landed. The UNO Q itself shipped in October 2025. If this board has
   been sitting in its box since launch, `/boot/efi/dtb/qcom/` may contain **no media
   carrier overlays at all**, and the plan's starting template simply isn't there.
2. **An OS/kernel upgrade regenerates `/boot/efi` and overwrites the composed DTB**,
   and may rewrite the loader entry. Doing DT work first and updating later destroys
   the work and produces a maddening "it worked yesterday" failure.
3. **The kernel version decides the driver question.** Whether `tc358762` and
   `panel-simple` are present as modules, and whether on-device headers match the
   running kernel, both follow from which image is installed.

So: **update fully, then baseline, then freeze, then build.**

---

## A. Find out what you actually have

Run these on the board (`adb shell` or SSH) — they're also in `scripts/00-baseline.sh`:

```sh
cat /etc/os-release              # expect Debian 13 "Trixie" on current images
uname -r                         # expect 6.16.x on current images
dpkg -l | grep -i arduino        # arduino-app-lab / arduino-app-cli / arduino-cli versions
arduino-app-cli version 2>/dev/null || arduino-app-cli --version 2>/dev/null
ls /boot/efi/dtb/qcom/ | grep -i carrier-media   # THE decisive check
apt list --upgradable 2>/dev/null | head -50
```

That `grep -i carrier-media` is the one that matters. Two outcomes:

- **Overlays present** → the image is recent enough. Do the incremental update in B.
- **Nothing returned** → the image predates Media Carrier support. Go to C and reflash.
  Do it now, while there is nothing on the board worth losing.

If you see Debian 12 "Bookworm" rather than 13, that's an old image — reflash.

## B. Incremental update (recent image)

Three separate update tracks exist on this board, and they are genuinely independent:

```sh
# 1. Arduino's own stack: App Lab, app-cli, arduino-cli, Zephyr core, router.
#    This is the CLI equivalent of the update App Lab offers you in its UI.
arduino-app-cli system update

# 2. Everything else in Debian
sudo apt update && sudo apt full-upgrade

# 3. Reboot, because this may well have installed a new kernel
sudo reboot
```

Afterwards re-check `uname -r` and re-run the `carrier-media` grep. Note that the
App Lab *host* application on your PC updates separately from the board — keep both
current or the pairing can get fussy.

## C. Full reflash (old image, or if B leaves you short)

Wipes the board completely and returns it to factory state — you reconfigure Wi-Fi,
board name and password afterwards. At this stage of the project that costs nothing.

1. Get the Arduino Flasher Tool from https://www.arduino.cc/en/software and extract
   `arduino-flasher-cli.exe`.
2. **With no power to the board**, find the **JCTL** header and short the two pins
   **furthest from the USB connector** (jumper or shunt). This selects Qualcomm EDL
   mode — the UNO Q flashes over EDL, not as a block device.
3. Keeping the pins shorted, connect the board to the PC over USB.
4. In PowerShell, from the extraction folder:

   ```powershell
   .\arduino-flasher-cli.exe flash latest
   ```

   Confirm the image download (`y`), then confirm the write (`y`). **This erases all
   data on the device.** Allow any driver install prompt on first run.

   Running `arduino-flasher-cli flash` with no arguments instead gives an interactive
   wizard: board variant, image version, whether to keep the user partition, and the
   root/home split. Worth using if you want to pick a specific image version.
5. Wait for "partition 0 is now bootable", disconnect, **remove the jumper**, reboot.
6. Re-run the first-setup wizard, then re-do `docs/01-connect.md` (ADB + SSH), then
   run B anyway — a freshly flashed image still typically pulls a component update,
   which can take longer than the flash itself.

## D. Freeze before you start the DT work

Once updated and baselined, stop the ground moving under us. A kernel upgrade
mid-bring-up will replace `/boot/efi/dtb/qcom/*` and silently undo a working
composition:

```sh
# see what's actually installed first
dpkg -l | grep -iE 'linux-image|linux-headers|device-tree|dtb'

# then hold the kernel + DT packages for the duration
sudo apt-mark hold <linux-image-pkg> <linux-headers-pkg> <dtb-pkg>
sudo apt-mark showhold
```

Release the holds when the panel works and the re-composition hook from Phase 6 is in
place — that hook is precisely what makes it safe to update again.

## E. Record the state you settled on

Before touching anything, capture what "working" looked like:

```sh
uname -r > ~/state.txt
cat /etc/os-release >> ~/state.txt
dpkg -l | grep -i arduino >> ~/state.txt
ls -la /boot/efi/dtb/qcom/ >> ~/state.txt
cp /boot/efi/dtb/qcom/qrb2210-arduino-imola.dtb ~/imola-known-good.dtb
cp -r /boot/efi/loader/entries ~/loader-entries-known-good
```

Pull that back to this repo (`docs/baseline.txt`) so the DTS we write is pinned to a
known kernel and a known overlay set.

# Step 1 — Getting a shell on the UNO Q (and a lifeline)

System facts (as shipped): **Debian 13 "Trixie" arm64, kernel 6.16**, default user
`arduino`, factory password `arduino` (only until you complete first setup, after
which your own password applies).

We want **two independent channels** before we touch the device tree:

| Channel | Survives no network? | Survives broken display DT? | Role |
| --- | --- | --- | --- |
| **ADB over USB-C** | yes | yes | **the lifeline / rollback channel** |
| SSH over Wi-Fi | no | yes | day-to-day work, file transfer |

ADB matters more than SSH here. Enabling the DSI panel re-points the SoC's only DSI
controller away from the ANX7625 bridge, which kills DisplayPort-over-USB-C. But ADB
runs over plain USB data on the same connector and is unaffected by the display
pipeline — so it keeps working even when the board boots to a black screen. That is
exactly the failure mode we're going to spend Phase 3 in.

---

## A. First setup (once)

1. Connect the UNO Q to your PC with a **USB-C cable directly** — not through a hub
   for this first step.
2. Open **Arduino App Lab** and complete the initial setup wizard. This is what
   enables SSH and sets your Linux password. Choose a board name you'll remember —
   it becomes the mDNS hostname.
3. While you're in App Lab, note whether there is a **display / hardware settings**
   page listing supported panels. If a 5-inch Waveshare option already exists there,
   that shortcuts a lot of Phase 3.

App Lab also has a built-in terminal (the `>_` icon, bottom left) — handy, but it is
not a lifeline, because it depends on App Lab being able to reach the board.

## B. Set up ADB (the lifeline) — do this first

Install the platform tools on your Windows machine:

```powershell
winget install Google.PlatformTools
```

(macOS: `brew install android-platform-tools`; Debian/Ubuntu:
`sudo apt install android-sdk-platform-tools`)

Then with the UNO Q plugged into USB-C:

```powershell
adb devices
adb shell
```

`adb shell` should drop you straight in as `arduino`. **Verify this works before
doing anything else in this project.** If `adb devices` shows nothing, check the
cable is a data cable (not charge-only) and that App Lab isn't holding the port.

## C. Set up Wi-Fi and SSH

From an `adb shell` (or the App Lab terminal):

```sh
# list networks
nmcli dev wifi list

# join one
sudo nmcli dev wifi connect "<SSID>" password "<PASSWORD>"

# confirm, and get the address
nmcli
hostname -I
ip addr show wlan0
```

Then from your PC:

```powershell
ssh arduino@<boardname>.local
# or, if mDNS is flaky on Windows:
ssh arduino@<the IP from hostname -I>
```

Worth doing while you're here: reserve a static DHCP lease for the board's `wlan0`
MAC on your router. A moving IP is an annoyance we don't need mid-bring-up.

If you ever re-flash the board and SSH complains about a changed host key:

```powershell
ssh-keygen -R <boardname>.local
```

## D. Verify the lifeline properly (don't skip)

Before Phase 3, prove the recovery path actually works:

1. Unplug Ethernet / disable Wi-Fi on the board, or just move out of range.
2. Confirm `adb shell` **still** gets you a root-capable shell.
3. Confirm you can write to `/boot/efi/loader/entries/` from that shell.

If all three hold, a bad device tree is a 2-minute rollback rather than a re-flash.

## E. Then update, then baseline

**Do [docs/02-update.md](02-update.md) before the baseline below.** An old image may
not contain the Media Carrier overlays this project builds on, and an update run later
would overwrite the DTB we compose. Update first, baseline second.

Once updated:

```powershell
scp scripts\00-baseline.sh arduino@<boardname>.local:~/
ssh arduino@<boardname>.local "sh 00-baseline.sh" > docs\baseline.txt
```

Or over ADB:

```powershell
adb push scripts\00-baseline.sh /home/arduino/
adb shell "sh /home/arduino/00-baseline.sh" > docs\baseline.txt
```

Send me `baseline.txt` and I'll read off it: which panel/bridge drivers the 6.16
kernel already carries, exactly which DTBs and overlays Arduino ships, whether the
TC358762 bridge module is present, and whether we can build modules on-device.

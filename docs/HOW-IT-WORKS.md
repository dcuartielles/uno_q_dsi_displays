# How it works, and why it needs patched drivers

Short version: the UNO Q's kernel is close to mainline, and **mainline has
repeatedly trimmed vendor code that these panels depend on**. Three separate
things had to be put back — and one hardware quirk had to be worked around.

---

## The display pipeline

```
  Qualcomm QRB2210 (SoC)
        |
    mdss_dsi0            ONE DSI controller on the whole SoC
        |
   JMEDIA connector      carrier is passthrough
        |
   DSI0 FPC (22-pin)     1.8 V signalling, +3V3 on pin 22, I2C on 20/21
        |
   [ your panel ]        on-panel bridge (e.g. ICN6211) self-configures
```

Because the SoC has **one** DSI controller, enabling a panel takes it away from
the ANX7625 bridge that drives DisplayPort over USB-C. `arduino-linux-config`
enforces this: *"Incompatible overlays, removing …video_sound-usbc.dtbo"*.

Panels split into two families:

- **Self-configuring bridge** (Chipone ICN6211 and similar). The host attaches
  the panel directly as a DSI device. **No bridge node.** This is what the
  generator emits, and what Raspberry Pi does for the Waveshare 800×480.
- **Host-programmed bridge** (Toshiba TC358762, as on the official Pi 7").
  Needs a bridge node and a driver that programs its DPI timing registers.

Getting this distinction wrong produces a fully healthy-looking pipeline —
connector connected, correct mode, framebuffer scanning out — and a blank
screen, with nothing in the logs.

---

## The three patches

### 1. `panel-simple` — no generic `panel-dsi` binding upstream

Raspberry Pi added a generic `"panel-dsi"` device-tree binding, where timings,
lane count, colour format and mode flags all come from the DT. **Mainline has
neither the binding nor the driver support.**

Rather than backport the whole DT-driven path, `tools/gen-panel-patch.py`
generates a fixed `panel_desc_dsi` from your `.panel` file and adds it to
`panel-simple`'s DSI match table. Equivalent result, much smaller patch.

### 2. `edt-ft5x06` — three independent problems

**No interrupt.** The carrier's DSI connector has no touch IRQ line — pins 17
and 18 are `NC`, where the camera connectors have `POWER_EN` and `GPIO1`.
Mainline hard-requires an interrupt:

```
edt_ft5x06 0-0038: Unable to request touchscreen IRQ.
probe with driver edt_ft5x06 failed with error -22
```

Raspberry Pi's driver polls at 60 fps instead; their DT for these panels has no
interrupt either. Backported.

**Long I²C reads fail.** Mainline issues one `regmap_bulk_read` of
`point_len * max_support_points + tdata_offset` — 33 to 63 bytes — which returns
`-ENXIO` on the Qualcomm **CCI** I²C controller. CCI is a camera-oriented master
and cannot do long transfers. Reproducible from userspace: an 8-byte read
succeeds, a 32-byte read fails. Patched to read the 3-byte header, take the
contact count from `TD_STATUS`, then fetch only those points.

**Identification is not retried.** `edt_ft5x06_ts_identify()` is the first I²C
traffic to the controller, and mainline gives up on the first error:

```
edt_ft5x06 0-0038: touchscreen probe failed
probe with driver edt_ft5x06 failed with error -110
```

One `-ETIMEDOUT` there loses the touchscreen for the whole session even though
the identical probe succeeds moments later. Now retried against a deadline,
pulsing the controller's reset in between. That covers a brief hiccup; the
minute-long outages are handled by the recovery service below.

Also brought across: RPi's released-contact tracking, because the controller
does not reliably report `TOUCH_UP` and contacts otherwise stick.

### 3. `rpi-panel-attiny-regulator` — absent, and needs hardening

Not shipped in the UNO Q's kernel at all, so it is built from source. Two
changes:

**Unchecked writes.** `attiny_set_port_state()` ignores `regmap_write()`'s
return value entirely. On this board the writes that assert `PC_LED_EN` and
release the panel resets intermittently fail:

```
WRITE reg=0x83 val=0x01 ret=-110     PC_LED_EN never asserted
WRITE reg=0x83 val=0x0d ret=-110     resets never released
```

…and the panel then never lights, with nothing logged. Now retried against a
short deadline. In practice most writes succeed first try and a few need two or
three attempts — so the retry is doing real work, and this is a genuine upstream
robustness bug worth reporting.

**`is_enabled` reads the chip.** Mainline reads `PORTC` back to decide whether
the regulator is on. This panel always returns `0x10` there, so the regulator
reports `disabled` while actually powered. RPi uses the cached port state; we do
the same. This one cost hours of chasing a phantom.

---

## The fourth piece: a recovery service

**Measured:** without it, 5 of 6 cold boots came up with the panel black while
every software check reported the display healthy. With it, 6 of 6 boots that
hit the bug came up working (Fisher exact p = 0.0022). Full numbers and method
in [../bench/RESULTS.md](../bench/RESULTS.md).

The failure is narrower than it looks. On a cold boot the CCI bus is dead for
the first 30-90 seconds and the controller's writes fail - but the DSI link,
the panel resets and the rendered image all survive. The only casualty is the
backlight PWM, so the screen is dark while showing a perfectly good picture.

Software cannot see this. DRM reports a connected connector scanning out a
framebuffer; the controller's registers do not read back. It took a camera to
find it, which is what `bench/` exists for.

The service waits for the controller to answer over I2C - `REG_ID` is a
harmless read - and only then re-asserts the backlight. An earlier version did
it on a fixed timer and failed, because the timer expired while the bus was
still down; it logged success while the screen stayed black.

**This is a workaround, not the right fix.** The panel is still dark for about
a minute (measured: 63 s), and the proper fix belongs in the driver's enable
path, retrying REG_PWM until the controller answers rather than giving up after
ten tight attempts.



Not a patch, a workaround. On some boots the CCI I²C bus is dead for the first
minute — every transfer to `0x45` and `0x38` returns `-ETIMEDOUT`, hundreds of
`master 0 queue 0 timeout` lines appear, and the drivers give up. On other
boots of the identical image there are two timeouts in total.

Nothing in the driver can fix that: no retry deadline helps when the bus is out
for 95 seconds, and a long one only stalls boot for a minute per write. (This
is why the attiny retry budget is deliberately short — 2 s, enough for the
"needs two or three attempts" case that is common, not enough to wedge boot.)

What does work is asking again later. `uno-q-dsi-panel-recover.service` waits
for boot to settle, checks whether the panel and touchscreen actually came up,
and reloads the touch driver if not. In testing it typically recovers in one or
two attempts.

The display is not recoverable this way, because bringing the panel back means
re-running the DSI attach. In practice it usually survives anyway: the panel
controller is a separate MCU that keeps its port state across a warm reboot, so
the panel stays lit even on a boot where every write to it failed. A *cold*
boot into the bad case does leave the panel dark, and the answer is a power
cycle. Better power makes the bad case markedly rarer.

---

## How a panel is identified

It is worth being clear about what this is **not**: there is no tree walk. Every
panel definition is an independent predicate, run against the bus on its own,
and the rule is that **exactly one** must match. The tree below is the shape the
*data* happens to form - which is precisely why collisions are possible at all,
and why the tool stops and asks rather than following a branch.

### The run

```
  detect-panel.sh
       |
       v
  find the carrier's I2C bus
       |     bus numbering is not stable across boots,
       |     so it is found, never assumed
       v
  is the bus stuck low? --- yes ---> STOP
       |                  "THE I2C BUS IS NOT WORKING"
       | no               power / cable / connector
       v
  run EVERY definition's probe chain,
  independently; all stages must match
       |
       v
  how many matched?
       |
       +-- 0 ---->  STOP
       |            "no known panel recognised"
       |
       +-- 1 ---->  install it
       |
       +-- 2+ --->  STOP and ask
                    not interchangeable, so a
                    guess is 50/50 wrong
```

### What the bytes say

```
0x45   REG_ID (0x80)
  |
  +-- c3 or de ....... waveshare-800x480
  |                    (4.3in + 5in, LCD line)
  +-- anything else .. not the LCD line


0x5d   product ID (0x8140)
  |
  +-- "911" --> 0x8048 resolution
  |      |
  |      +-- 720 x 1280 ... arduino-5in-touch-a
  |      +-- 1024 x 600 ... waveshare-7in-touch-c
  |
  +-- "9271" --> 0x8053 thresholds
         |
         +-- 5f 41 ....... arduino-8in-touch-a
         +-- 64 32 ....... arduino-12in-touch-a
         +-- 64 46 ....... waveshare-4in-touch-c
         |
         +-- 50 32 ....... AMBIGUOUS, needs one more
                |
                +-- 0x8048 resolution
                       |
                       +-- 800 x 1280 ...
                       |     arduino-10in-touch-a
                       +-- 480 x 1920 ...
                             waveshare-8in8-touch-a
```

Three things the shape tells you.

**Depth is forced, not chosen.** The 10.1 inch and 8.8 inch need three stages
because they agree on *both* the product ID and the thresholds. The 8 inch
needs two. Every stage exists to exclude something specific, which is why a
stage that excludes nothing only adds a way to fail.

**The two branches never meet, and that is a blind spot.** `0x45` and `0x5d`
look like separate subtrees here, but every TOUCH panel *also* carries a chip
at `0x45`. Nothing recorded says what it answers, so the left branch has never
been tested against a TOUCH panel in either direction. See
[RETEST-CHECKLIST.md](RETEST-CHECKLIST.md).

**The `50 32` node is where a panel got misidentified.** Before 1.13.0 it had
no third level, so the 8.8 inch fell straight through to
`arduino-10in-touch-a` - confidently, and wrongly. `tools/check-fingerprints.py`
exists to catch that shape of fault without hardware.


## Why the 5-inch slot gets reused

`arduino-linux-config` is a Go binary with its carrier definitions compiled in —
option names *and* `.dtbo` filenames both. `strings` on the binary shows them.
There is no config file and no `set` subcommand, so a new display option cannot
be registered.

So the overlay is installed as the 5-inch `.dtbo` and selected with
`display=5-dsi-touch-a`. Arduino's original is preserved and restored on
uninstall.

---

## Things that cost time, recorded so they don't cost yours

- **Power.** On a PC USB port the panel's I²C writes fail intermittently and the
  display never comes up. It looks exactly like a driver bug. Use 5 V/3 A.
- **The clock.** No RTC battery, so before NTP syncs every apt repository fails
  signature verification with `Not live until <date>`. Looks like a broken
  mirror; it is the date.
- **`arduino-app-cli system update` does nothing useful.** It exits 0 having
  changed nothing, and only ever touches already-installed packages, so it can
  never pull the new kernel. Use `apt` directly.
- **`bootctl set-oneshot` does not work here.** EFI variables are read-only, so
  the usual "boot this once" safety net is unavailable. The firmware boots the
  newest loader entry. Keep a shell you can reach — ADB over USB-C survives a
  device tree that leaves the board with no video at all.
- **I²C bus numbers are not stable across boots.** The same device appeared as
  `0-0045`, `1-0045` and `2-0045` on different boots. Never hardcode them;
  locate devices by address.
- **Vendor documentation can name the wrong overlay.** Waveshare's wiki pointed
  at the Pi 7" overlay, which describes a TC358762. The panel has an ICN6211.
  The silkscreen settled it.

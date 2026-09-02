# Reliability benchmark

Answers **"how often does this actually work, and what correlates with the
times it doesn't"** — not "does it work on my desk right now".

It exists because the panel is intermittent. On some boots the Qualcomm CCI
I²C bus is dead for the first ~90 seconds and everything fails; on other boots
of the *identical image* there are two timeouts in total and it all works. You
cannot judge that by trying once.

---

## The two things that make this hard

**1. Software cannot tell you whether the panel is on.**

- The panel controller's registers don't read back what you write — `PORTB` and
  `PORTC` return a fixed `0x85` / `0x10` regardless. (Same quirk that broke
  mainline's `is_enabled()`.)
- A DRM connector can report `connected`, carry a mode and scan out a
  framebuffer **while the screen is completely dark**. That is the exact
  failure that took longest to find by hand.
- The backlight can't even be switched off from software: `brightness=0` and
  `bl_power=1` both only *dim* it, because this panel has a deliberately
  visible minimum brightness.

So the benchmark needs a **camera**. There is no software substitute.

**2. A warm `reboot` is not a valid test.**

The panel controller is a separate MCU that keeps its port state across a warm
reboot. We measured a boot with **565 CCI timeouts where every single attiny
write failed and the display still showed a picture** — because the controller
was still configured from the previous boot. From a cold start, that same boot
would have left the panel dark.

Only cutting power re-exercises the enable path. Every iteration must
power-cycle.

---

## What you need

| Thing | Why | Required? |
| --- | --- | --- |
| A webcam pointed at the panel | The only ground truth. Any USB webcam. | **Yes** |
| A way to cut power | Cold boots. Manual works; a smart plug makes it unattended. | **Yes** |
| SSH to the board | Collecting per-boot metrics. | **Yes** |
| `opencv-python`, `numpy` on the host | Image analysis. | **Yes** |

**Manual power cycling works** — the harness prompts you each cycle — but it
ties you to the desk, so plan on N≈20–30. With a smart plug (Shelly, Tasmota,
Kasa) or a switchable USB hub, pass `--power-off-cmd` / `--power-on-cmd` and
N=100 runs unattended in about 3½ hours.

---

## Setup

```bash
pip install opencv-python numpy

cat > bench/bench.conf <<'EOF'
UNOQ_HOST=192.168.1.50
UNOQ_USER=arduino
UNOQ_SSH_KEY=~/.ssh/unoq
UNOQ_SUDO_PASS=...            # omit if you set up NOPASSWD sudo
EOF

scp bench/board/*.sh arduino@<board>:~/bench/
ssh arduino@<board> 'chmod +x ~/bench/*.sh; sudo apt-get -y install kbd'
```

`kbd` provides `chvt`, which the pattern tool needs.

Then calibrate the camera once, with the panel in view:

```bash
python bench/optical.py devices          # find the camera index

python bench/optical.py calibrate --camera 1 \
  --dark-cmd    "sh bench/remote.sh '~/bench/panel-pattern.sh black 0'" \
  --solid-cmd   "sh bench/remote.sh '~/bench/panel-pattern.sh white 255'" \
  --content-cmd "sh bench/remote.sh '~/bench/panel-pattern.sh restore'"
```

A good calibration looks like this (measured on the reference board):

```
panel occupies 37.4% of the frame
contrast:  dark 0.12 | content 2.57 | solid 11.63
edge:      solid 0.11 | content 4.75
thresholds: lit >= 0.56, image >= 0.71
```

Re-calibrate whenever the camera or the room lighting moves.

---

## Running it

```bash
# manual power cycling - you are prompted to unplug/replug
python bench/benchmark.py boot --iterations 20 --camera 1

# unattended, with a smart plug
python bench/benchmark.py boot --iterations 100 --camera 1 \
  --power-off-cmd "curl -s http://plug/relay/0?turn=off" \
  --power-on-cmd  "curl -s http://plug/relay/0?turn=on" \
  --notes "PSU A 5V3A, cable 2, kernel 7.0.0"

python bench/analyze.py bench/results/<run-id>
```

Use `--notes` for whatever you are varying — it is stored with the run and
printed in the report, which is what makes two runs comparable.

---

## How the panel is judged

Three references at calibration, because two aren't enough:

| reference | what it represents |
| --- | --- |
| black @ min backlight | as close to off as this panel gets |
| **solid white** | **lit but featureless — the "backlight on, nothing rendered" failure** |
| the normal boot screen | a real, working display |

The key insight: **brightness is a poor success signal, structure is a good
one.** The Arduino login screen is mostly dark blue, so calibrated against
white it measured "dark" — a false failure. Measured by *edge energy* it scores
4.86 against 0.11 for solid white, a ~44× margin.

Validated truth table on the reference board:

| shown on panel | state | `has_image` | correct? |
| --- | --- | --- | --- |
| black | dark | false | yes |
| red / green / blue / white | lit | false | yes — lit but no content |
| the desktop | lit | **true** | yes |

Colours are verified too: painting red, green and blue and confirming the
camera agrees proves the DSI data path carries correct pixels, not merely that
something is glowing.

A boot passes only when **software and camera agree**: the pipeline is up *and*
the camera sees a real image.

---

## What the report tells you

Beyond the pass rate — which comes with a Wilson confidence interval, because
"20/20" honestly means 84–100%, not 100% — it compares failing boots against
passing ones across CCI timeouts, attiny write failures, touch probe failures
and boot timings, and names the strongest separator.

That is the real output. Knowing you are at 82% is far less useful than knowing
every failure had hundreds of CCI timeouts while every pass had two.

The outcome `fail_dark_panel` is the one to watch: software healthy, panel
blank. Only the camera can see it.

---

## The other suite: installer compatibility

Boards in the field run different kernels, and `install.sh` patches driver
sources by matching anchor text — so a kernel bump can silently break it. This
checks every kernel line, **with no hardware at all**:

```bash
python bench/install-matrix.py
```

It downloads the three driver files from each `*-unoq` branch, runs all three
patch tools, and verifies each is idempotent. Currently green on
`qcom-v6.16.7-unoq`, `qcom-v6.19.0-unoq` and `qcom-v7.0.0-unoq`.

It proves the patches *apply*, not that they *compile* — compiling needs
headers for that exact kernel, which only exist on a board running it.

---

## Honest limitations

- **The `bars` pattern is not detected as an image.** Eight wide vertical bars
  have very few edge pixels for their area, so they score like a solid colour.
  Real desktops are fine; be aware if you add sparse test patterns.
- **Room lighting must stay constant** across a run. The metrics are
  exposure-invariant (panel measured relative to its surroundings), which
  handles the camera's auto-gain, but not someone switching the lights.
- **Manual power cycling caps N** at whatever your patience allows.
- **One board at a time.** Comparing boards or supplies means separate runs;
  use `--notes` and pass several result directories to `analyze.py`.

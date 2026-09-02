# Measured results

Cold-boot reliability of the Waveshare 5" DSI panel on an Arduino UNO Q +
Media Carrier, kernel `7.0.0-g122c2c22d838`, external 5 V supply, measured with
a webcam because software cannot see this failure.

All numbers below are from `bench/results/`. Nothing here is estimated.

---

## The failure

**On roughly 3 in 4 cold boots the panel comes up black while every software
check reports the display healthy.**

```
connector : card0-DSI-1   connected
mode      : 800x480
/dev/fb0  : present
touch     : working
software_ok : 1              <-- everything says fine
camera      : state=dark, has_image=false
```

The cause is narrow. On a cold boot the Qualcomm CCI I²C bus is dead for the
first 30–90 seconds, and the panel controller's writes fail. Everything
survives that **except the backlight PWM**. The DSI link, the panel resets and
the rendered login screen were all correct on every single failed boot — the
screen simply was not lit.

Proof: on a dark boot the camera read `has_image=false` at edge 0.006, and the
instant `REG_PWM` was rewritten it read `has_image=true` at edge 5.122, showing
the login screen that had been there the whole time.

### Why it survived development

Two reasons, both worth knowing:

- **Software cannot detect it.** DRM reports a connected connector carrying a
  mode and scanning out a framebuffer. The panel controller's registers do not
  read back either — `PORTB`/`PORTC` return a fixed `0x85`/`0x10` whatever you
  write. There is nothing to query.
- **Warm reboots hide it entirely.** The controller is a separate MCU that
  keeps its port state across a warm reboot, so the panel stays lit even when
  every write failed. Every reboot used to validate the installer during
  development was warm, so the cold path was never exercised.

---

## Results

Bad boot = a boot where the controller's writes actually failed
(`attiny_write_failures > 0`). Only those can show whether a fix works; a clean
boot proves nothing.

| configuration | overall | bad boots rescued |
| --- | --- | --- |
| no fix | 1/6 | **0/5** |
| fix v1 — re-assert on a fixed timer | 0/1 | 0/1 |
| **fix v2 — wait for the bus, then re-assert** | **9/9** | **6/6** |

```
BAD BOOTS ONLY        dark   working
  no fix               5        0
  fix v2               0        6
  Fisher exact two-tailed p = 0.0022
```

The separation is complete, and the difference is significant despite the small
sample. Recovery rate for fix v2 is **6/6 = 100%, 95% CI 61–100%** — the point
estimate is perfect, the interval is honest about six samples.

### Why fix v1 failed

It re-asserted the backlight on a fixed timer, which was hope rather than
engineering. The service starts 40–60 s into boot but outages run to 87 s, so
on a bad boot the rescue write failed exactly like the boot-time writes — while
logging `re-asserted backlight`. A fix that lies is worse than no fix.

Fix v2 probes the controller (`REG_ID` is a harmless read) and waits until it
actually answers before writing. It also clears `bl_power` first, because
`backlight_get_brightness()` returns 0 while blanked and would otherwise push
PWM=0 regardless of how healthy the bus was.

---

## What this is NOT

**This is not "drivers that boot correctly 100% of the time".** Three honest
qualifications:

1. **The bug is untouched.** The controller's writes still fail on ~3 of 4 cold
   boots. What was added is a repair after the fact.
2. **The screen is black for about a minute.** Measured on a live bad boot: the
   backlight was re-asserted at **63.2 s**, and the panel was dark until then.
   For a kiosk or a product, that is a visible defect, not a fix.
3. **6/6 is not proof of 100%.** The interval is 61–100%. What is solid is the
   comparison, not an absolute claim.

A real fix belongs in the driver's enable path — retrying `REG_PWM` until the
controller answers, instead of giving up after a tight loop of ten attempts.
That would light the panel at boot rather than a minute later. The recovery
service is the pragmatic fix, not the right one.

---

## The bimodal signature

Boots fall into two sharply separated populations, with nothing in between:

| | CCI timeouts | attiny write failures | touch bound at |
| --- | --- | --- | --- |
| clean boot | 1–2 | 0 | 12 s |
| bad boot | 80–328 | 5–15 | 99 s |

No overlap. That rules out marginal timing or a weak supply, both of which
would produce a spread, and points at a state the CCI controller lands in at
power-on. **The underlying cause is still unexplained** — this work made the
symptom survivable, it did not find out why the bus dies.

---

## Evidence

`results/evidence/` holds two camera frames of the same board minutes apart:

- `panel-dark-before-fix.png` — a bad boot, software reporting everything
  healthy, screen black
- `panel-working.png` — the same board after the backlight was re-asserted

Per-iteration records are in `results/<run>/iter-NNN.json`, each combining the
board's own report with the camera's verdict. Re-analyse any of them with:

```bash
python bench/analyze.py bench/results/cold-fixed4
```

---

## Reproducing

```bash
python bench/optical.py calibrate --camera 1 ...   # see bench/README.md
python bench/benchmark.py boot --iterations 20 --camera 1
python bench/analyze.py bench/results/<run-id>
```

Every iteration must be a real power cycle. A `reboot` loop measures the wrong
thing and will report a success rate far too high.

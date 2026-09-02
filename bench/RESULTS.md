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

The cause is narrow. On a cold boot, writes to the panel controller at 0x45
fail for roughly the first 30-40 seconds. Everything
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

## Root cause, and the driver fix

The "correction" below was itself wrong, and the truth turned out to be
uncomfortable: **we were causing most of this ourselves.**

With the attiny driver blacklisted, a boot that would normally fail shows
**zero** CCI timeouts and every device on the bus answering from 8 seconds.
Merely loading the module drives that to 87 on demand. Measured per 32 writes:

| register | failures | bus afterwards |
| --- | --- | --- |
| `PWM` | 0 | fine |
| `PORTB` | 0 | fine |
| `PORTA` | 6 | fine |
| **`PORTC`** | **29** | **wedged** |

`PORTC` *reads* are completely safe. `PORTC` **writes** fail 50-90% of the
time, and as few as **four writes with two failures** wedge the entire CCI bus
for ~85 seconds - taking the backlight PWM write and the touch probe down with
it. The dark panel and the missing touchscreen were never separate faults; they
were collateral damage.

And two of our own patches were feeding it: the attiny retry loop turned a
handful of failed writes into 100+, and the touch identify-retry pulsed the
reset line, which is a GPIO on the panel controller driven over the same bus -
two more `PORTC` writes per pulse, ~60 per probe. Raspberry Pi's driver, diffed
against ours, does exactly one write per port change and discards the error.
Same regmap config, same probe, same 5-10ms spacing. The difference is the I2C
controller: Broadcom tolerates it, Qualcomm's CCI does not. Spacing is not the
answer either - 50ms and 200ms gaps both still wedged the bus.

**The fix:** `PORTC` gets exactly one attempt, never retried. Other registers
keep a small retry. Touch identify retries no longer touch the reset line.

### Measured, cold boots, counting only boots that hit the bug

| configuration | bug-hit boots ending lit | how |
| --- | --- | --- |
| no fix | **0/5** | - |
| recovery service only | 6/6 | rescued at ~63 s |
| driver fix only | 3/4 | **lit at boot** |
| **driver fix + fast service** | **7/7** | 4 lit at boot, 3 rescued at ~38 s |

```
no fix vs driver fix + service, bug-hit boots: 5/5 dark vs 0/7 dark
Fisher exact two-tailed p = 0.00126
```

Full run of 8 cold boots with both fixes - 8/8 passed:

```
iter  cci    attiny  outcome
1     16     3       lit at boot
2     1      2       lit at boot
3     132    4       rescued
4     17     4       lit at boot
5     0      0       lit at boot
6     159    9       rescued
7     141    8       rescued
8     160    9       rescued
```

The split matters more than the 8/8. **Both layers do real work:** the driver
fix handles the light cases (2-4 lost writes, `cci` 0-17, panel lights at
boot); the service catches the heavy ones (4-9 lost writes including
`PC_LED_EN`, so the panel really is dark and gets repaired at ~38 s). Neither
alone reaches 8/8 - the driver-fix-only run failed exactly once, on a lost
`PC_LED_EN` write.

Note the high `cci` counts on rescued boots are largely **the service's own
polling** while it waits for the controller to answer, not additional faults.
With the service enabled, `cci_timeouts` is no longer a clean measure of bus
health.

Touch improved independently: it now binds at **12 s on the first probe**,
instead of failing and being reloaded at 99 s.

### Still not solved

`PORTC` writes still fail 50-90% of the time. We stopped amplifying that into a
bus-wide outage, and we repair the one consequence that matters, but **why the
attiny mishandles PORTC writes on CCI is unexplained**. The genuinely correct
fix is a deferred `REG_PWM` re-assert inside the driver, which would remove the
userspace service entirely and light the panel in seconds rather than 38.

---

## Correction: "the CCI bus is dead" is probably wrong

Most of this work described the failure as the CCI I2C bus dying for the first
30-90 seconds. The boot timeline does not support that:

```
[ 4.07s] pca953x 0-0026: bound OK            <-- same bus, working fine
[10.31s] attiny: write reg=0x83 failed -110
[32.13s] attiny: last failure
[65.27s] edt_ft5x06 0-0038: probe succeeds
```

`pca953x` shares the bus and bound cleanly *before* the failures began, and the
touch controller's failure is downstream - its reset line is driven through the
attiny over I2C, so it cannot probe while the attiny is unresponsive.

So the evidence now points at the **panel controller alone being unresponsive**,
not a dead bus. That also explains the warm-reboot immunity better than a bus
fault does: across a warm reboot the controller stays powered and running.

This matters because it changes the fix: an unready device needs patience in
the driver, a stuck bus needs I2C bus recovery. The experiment that settles it
is in [../docs/BUG-STRATEGY.md](../docs/BUG-STRATEGY.md).

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

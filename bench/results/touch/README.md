# Does the touchscreen survive a boot?

Raw logs from `bench/touch-boots.sh`, and the measurement behind the claim that
the touch driver now recovers from a wedged I2C bus on its own.

## The question

On this hardware the CCI I2C bus is frequently unusable for the first minute or
so of a boot. The released `edt-ft5x06` spun on it for 8 s, gave up, and the
touchscreen was gone for the session — `35-install-recovery.sh` rebound the
module about 100 s later.

The driver now defers instead: probe succeeds, and bring-up retries from a work
item every 5 s for up to 150 s, holding nothing in between. Does that actually
rescue a boot?

## Method

Warm reboots, not cold ones — deliberately, and it needs justifying, because
every other measurement in `bench/` insists on cold boots.

The *dark panel* half of this bug needs a real power cycle: the backlight
enable path only misbehaves from cold. The *touch* half does not. The wedge is
caused by the drivers' own I2C traffic as they load, so `systemctl reboot`
reproduces it — about one boot in three here. That makes this cheap enough to
run between edits, with no smart plug and nobody at the socket.

These are therefore **not** comparable to the cold-boot figures in
`RESULTS.md`, and are kept out of `tools/check-docs.py` so the two
methodologies cannot be averaged together by accident.

**The recovery service was disabled for both arms.** With it enabled it rebinds
the touch driver after ~100 s and every boot looks like a success regardless of
what the driver did — which is precisely the question. Both arms were built and
installed through the identical DKMS path; only the driver source differed.

## Scoring: bug-hit boots only

A boot that never wedges cannot show a difference — both drivers bind at ~12 s.
Including those boots does not make the comparison fairer, only diluted. The
split is drawn from the data rather than chosen; sorted timeout counts across
all 32 boots:

```
0 0 1 2 2 2 2 3 4 16 17 17 17 18 18 19 |
                 37 38 94 95 110 135 139 144 144 144 145 145 145 146 151 152
```

Nothing lands between 19 and 37, so any threshold in that gap classifies every
boot identically. That is what makes drawing one defensible instead of a knob
that could be tuned until the answer came out right.

## Result

| | wedged boots with touch | clean boots with touch |
| --- | --- | --- |
| released driver (`baseline-*.log`) | **0 / 11** | 5 / 5 |
| with the fix (`fixed-*.log`) | **5 / 5** | 11 / 11 |

Fisher two-tailed **p = 0.00023**.

Reproduce with:

```bash
python bench/touch-analyze.py 'bench/results/touch/baseline-*.log' \
                    --against 'bench/results/touch/fixed-*.log'
```

The mechanism is in the logs, not merely inferred from the arithmetic. Every
rescued boot said so:

```
edt_ft5x06 0-0038: I2C bus busy, finishing touchscreen setup in the background
edt_ft5x06 0-0038: touchscreen came up 12388 ms into the retry window
```

The wedge itself is unchanged — 94 to 152 timeouts in both arms. The driver
simply stops losing the touchscreen to it.

## Shipping configuration

`shipping-config.log` is the combination users actually get: the fixed driver
**and** the recovery service enabled. 6 of 6 boots had touch, and the service
stood aside where it used to intervene:

```
uno-q-dsi-panel: re-asserted backlight 0-0045 (brightness 255)
uno-q-dsi-panel: display is up
uno-q-dsi-panel: touch is up
```

That check mattered. With the driver recovering at ~27 s, the service would
otherwise have begun `modprobe -r` cycling at about the same moment, cancelling
the driver's deferred work and restarting the wait — two mechanisms fighting
over one bus, which is what caused this bug in the first place. The service now
waits for the driver's own deadline and steps in only if it gives up.

## What this does not fix

The dark panel. The backlight lives behind the same wedged bus and the same
lost ATTINY writes, and nothing here addresses it — `35-install-recovery.sh`
still re-asserts the backlight on every boot that needs it, as the log above
shows. Its touch role is now a backstop; its backlight role is not.

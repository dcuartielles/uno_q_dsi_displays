# Strategy for actually fixing the cold-boot bug

The recovery service makes the symptom survivable. It does not fix anything:
the panel is still black for about a minute (measured: 63 s), and the driver
bug is untouched. This is a plan to fix it properly.

---

## 1. What is established

Measured over cold boots with a camera (see [../bench/RESULTS.md](../bench/RESULTS.md)):

- On ~3 cold boots in 4, writes to the panel controller at `0x45` fail with
  `-ETIMEDOUT` from roughly 8 s to 40 s after power-on.
- The **only** lasting casualty is the backlight PWM. The DSI link, the panel
  resets and the rendered image are all correct — the screen is simply unlit.
  DRM says so explicitly: `failed to enable backlight: -110`.
- The failure is **bimodal**: clean boots show 1–2 CCI timeouts and zero write
  failures, bad boots show 80–328 and 5–15. No overlap, ever.
- **Warm reboots never reproduce it.** The controller is a separate MCU that
  retains state across a warm reboot.
- By 65 s the bus works normally, and stays working.

## 2. What was assumed, and is now in doubt

Throughout this work the failure was described as "the CCI I²C bus is dead for
the first 30–90 seconds". **The boot timeline does not support that**, and the
distinction decides which fix is correct:

```
[ 4.07s] pca953x 0-0026: bound OK            <-- same bus, working fine
[ 7.69s] attiny module loads
[10.31s] attiny: write reg=0x83 failed -110  <-- failures begin
[32.13s] attiny: last failure
[32.57s] edt_ft5x06 0-0038: probe failed
[65.27s] edt_ft5x06 0-0038: probe succeeds
```

`pca953x` sits on the *same* CCI bus and bound cleanly at 4 s. And the touch
controller's failure is **downstream**, not independent evidence: its reset
line is driven through the attiny's GPIO expander over I²C, so it cannot probe
while the attiny is unresponsive.

That leaves a much more specific hypothesis:

> **H1 — the attiny alone is unresponsive for the first ~30–60 s of a cold
> boot.** It is an MCU running its own firmware, powered from the panel's 3V3
> rail via the DSI FPC. On a cold start it powers up with the board; on a warm
> reboot it is already running. That would explain the warm-reboot immunity
> exactly, and the bimodality (it either came up cleanly or it did not).

Competing hypotheses, still open:

> **H2 — the bus wedges.** A device that powered up mid-transaction can hold
> SDA low and lock the bus. Bimodal fits. But `pca953x` working at 4 s and
> everything working at 65 s argues against a persistent wedge, unless it is
> intermittent.

> **H3 — our own first transaction wedges it.** The attiny module is loaded
> from `modules-load.d` at 7.7 s, and the first failure is at 10.3 s. If the
> controller is mid-power-up when we first talk to it, the transaction may
> leave it (or the bus) stuck. This is uncomfortable because it would mean the
> workaround causes the bug.

> **H4 — clocks or power domains.** CCI belongs to the camera subsystem and
> both cameras are disabled in the overlay, so a clock or power domain may not
> be in the expected state early.

---

## 3. Experiments, cheapest and most decisive first

### E1 — Who is unresponsive: the attiny, or the whole bus?

**The single most important measurement.** During the failure window, probe
`0x26` (pca953x) and `0x45` (attiny) from userspace and record the *error
codes*. `ENXIO` means the address was NAKed — the device is not answering.
`ETIMEDOUT` means the transfer did not complete — the bus is stuck. They point
at completely different fixes.

SSH is not up early enough, so this must run from an early systemd unit and log
to a file. `bench/board/early-i2c-probe.sh` does exactly this; install it with
`bench/board/install-early-probe.sh`, cold-boot a few times, then read
`/var/log/uno-q-early-i2c.log`.

Outcomes:

| observation | conclusion | go to |
| --- | --- | --- |
| `0x26` answers while `0x45` NAKs | attiny is not ready — H1 | §4.1 |
| both fail with timeouts | bus is wedged — H2 | §4.2 |
| both fine until we load the module | we cause it — H3 | §4.3 |

### E2 — Does simply talking later avoid it?

Blacklist the module, cold-boot, wait, then load it by hand:

```bash
echo 'blacklist rpi_panel_attiny_regulator' | sudo tee /etc/modprobe.d/bench.conf
sudo rm /etc/modules-load.d/uno-q-dsi-panel.conf
sudo reboot        # then, after a cold boot:
sleep 90 && sudo modprobe rpi-panel-attiny-regulator
```

If the panel then comes up reliably, the fix is a deferral, and E1 tells us
whether to defer by time or by polling. Cheap, and it directly tests H1 and H3.

### E3 — When exactly does it recover?

`early-i2c-probe.sh` logs continuously, so the recovery moment falls out of E1.
A consistent recovery time (say always ~35 s) implies a timer or watchdog in
the attiny firmware. Recovery only *after traffic stops* implies contention or
a wedge, which is a different fix.

### E4 — Is SDA stuck low?

If E1 says the bus is wedged, check the lines directly during the window:

```bash
cat /sys/kernel/debug/pinctrl/*/pinconf-pins | grep -iA2 'cci\|i2c'
cat /sys/kernel/debug/gpio
```

A low SDA with an idle bus is conclusive.

### E5 — Clocks and power domains

Compare a clean boot with a bad one during the window:

```bash
grep -iE 'cci|camss' /sys/kernel/debug/clk/clk_summary
cat /sys/kernel/debug/pm_genpd/pm_genpd_summary
```

A rate or state that differs between the two populations would explain the
bimodality directly.

---

## 4. Fixes, by outcome

### 4.1 If the attiny is simply not ready (H1)

**Fix in the driver, not in userspace.** `attiny_lcd_power_enable()` gives up
after a short retry, and `attiny_update_status()` after ten tight attempts with
no delay — both far too impatient for a controller that needs 30 s.

Add a **deferred re-apply**: keep the desired port state and PWM in the driver,
and schedule delayed work that re-applies them until they stick or a generous
deadline (~120 s) expires. Boot is never blocked, and the panel lights the
moment the controller answers — around 35 s instead of 63 s, with no userspace
service at all.

This is also the right shape to send upstream, since mainline's
`attiny_set_port_state()` ignores `regmap_write()`'s return value entirely.

Cheaper interim: probe with `-EPROBE_DEFER` until `REG_ID` reads back, so the
driver simply does not attach until the controller is alive.

### 4.2 If the bus wedges (H2)

Use the kernel's standard I²C bus recovery: drive SCL manually for 9 cycles to
free a slave holding SDA. It is wired up in the device tree:

```dts
&cci_i2c0 {
    scl-gpios = <&tlmm N GPIO_OPEN_DRAIN>;
    sda-gpios = <&tlmm M GPIO_OPEN_DRAIN>;
};
```

This needs the CCI driver to support `i2c_bus_recovery_info` — check whether
`i2c-qcom-cci` does; if not, adding it is a small, upstreamable patch.

### 4.3 If our own first transaction causes it (H3)

Stop loading the module from `modules-load.d` at 7.7 s. Either delay it with a
timer unit, or make the driver wait for the controller to identify itself
before issuing any write. E2 tests this directly.

### 4.4 Independent of cause: never lie about it

`attiny_set_port_state()` currently discards write errors, so the panel can
fail to light with nothing logged. Even after a root-cause fix, the return
value should be checked and a failure logged loudly. That bug alone cost days
here.

---

## 5. Recommended order

1. **E1** — install the early probe, collect 5–10 cold boots. Everything else
   depends on knowing whether it is the attiny or the bus.
2. **E2** in parallel — it is nearly free and would immediately confirm or kill
   the "talk later" family of fixes.
3. Implement the fix §4.1/§4.2/§4.3 that the evidence selects.
4. **Re-run the benchmark** against the new driver. The bar is not "it worked
   for me": it is a cold-boot run where the panel is lit within a few seconds
   on boots that previously failed. `bench/` already measures exactly that, and
   `bench/RESULTS.md` holds the before/after baseline to beat.
5. Report upstream: the unchecked `regmap_write()` in
   `attiny_set_port_state()`, and whatever the root cause turns out to be if it
   is a kernel-side issue.

## 6. What "fixed" means

Not "the screen eventually appears". The target is:

- panel lit within a few seconds of boot on **every** cold boot, not after ~60 s
- no userspace recovery service required
- measured over at least 20 cold boots with the camera, since software cannot
  see this failure at all

#!/usr/bin/env python3
"""Harden rpi-panel-attiny-regulator for the UNO Media Carrier.

This driver runs the panel's power/backlight controller at I2C 0x45. It is not
shipped in the UNO Q's kernel, so we build it from source; two changes are
needed for it to work reliably here.

1. WRITES ARE NOT CHECKED. attiny_set_port_state() ignores the return value of
   regmap_write() entirely. On this board the writes that assert PC_LED_EN and
   release the panel resets intermittently fail with -ETIMEDOUT - and the
   panel then simply never lights, with nothing logged. Observed:
       WRITE reg=0x83 val=0x01 ret=-110    (PC_LED_EN never asserted)
   Now checked and logged - but deliberately NOT retried for REG_PORTC. See
   PORTC_ATTEMPTS below: retrying that register is what wedges the CCI bus,
   and a wedged bus is far worse than one lost write, because it also kills
   the backlight PWM write and the touch controller's probe.

2. is_enabled READS THE CHIP. Mainline reads PORTC back to decide whether the
   regulator is on. This panel always returns 0x10 for that register, so the
   regulator reports "disabled" while actually powered, which confuses the
   regulator core. Raspberry Pi's version uses the cached port state instead;
   we do the same.

Usage: patch-attiny-regulator.py <rpi-panel-attiny-regulator.c>
"""
import re
import sys

# Retries are register-aware, because a blanket retry loop was measured to be
# actively harmful.
#
# Writes to REG_PORTC fail 50-90% of the time on this board, and as few as FOUR
# of them (two failures) wedge the whole CCI bus for ~85 seconds. Everything
# else on the bus dies with it - which is what made the backlight PWM write
# fail and the touch controller fail to probe.
#
# An earlier version of this patch retried every failed write ~13 times, which
# on REG_PORTC turned a handful of failures into a hundred-plus write storm
# aimed at the one operation that wedges the bus. Measured: with this driver
# blacklisted a boot shows ZERO CCI timeouts, and merely loading it drives that
# to 87 on demand.
#
# PWM and PORTB measured 0 failures in 32 writes each, PORTA 6 in 32 with no
# wedge - so those are safe to retry.
PORTC_ATTEMPTS = 1
OTHER_ATTEMPTS = 3
OTHER_GAP_MS = 20


def main():
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    p = sys.argv[1]
    s = open(p).read()

    if "uno-q-dsi-panel" in s:
        print("  attiny regulator already patched")
        return
    s = "/* patched by uno-q-dsi-panel */\n" + s

    # 1. check writes, but retry only the registers that are safe to retry
    old = ("\tstate->port_states[reg - REG_PORTA] = val;\n"
           "\treturn regmap_write(state->regmap, reg, val);")
    if old not in s:
        sys.exit("attiny: set_port_state anchor not found")
    new = f"""\tint ret = 0, i;
\tint attempts = (reg == REG_PORTC) ? {PORTC_ATTEMPTS} : {OTHER_ATTEMPTS};

\tstate->port_states[reg - REG_PORTA] = val;

\t/*
\t * REG_PORTC is special, and dangerous on this board. Writes to it fail
\t * 50-90% of the time, and as few as FOUR of them - two failures - wedge
\t * the entire CCI I2C bus for about 85 seconds, taking every other device
\t * on the bus down with it. That is what makes the backlight PWM write
\t * fail and the touch controller fail to probe.
\t *
\t * So PORTC gets exactly ONE attempt. A single lost write here is
\t * survivable; a retry storm is not. The other registers are safe to
\t * retry and occasionally need it.
\t */
\tfor (i = 0; i < attempts; i++) {{
\t\tret = regmap_write(state->regmap, reg, val);
\t\tif (!ret)
\t\t\tbreak;
\t\tif (i + 1 < attempts)
\t\t\tmsleep({OTHER_GAP_MS});
\t}}
\tif (ret)
\t\tpr_warn("attiny: write reg=0x%02x val=0x%02x failed after %d attempt(s): %d\\n",
\t\t\treg, val, attempts, ret);
\treturn ret;"""
    s = s.replace(old, new, 1)

    # 2. is_enabled from the cache, as RPi does
    m = re.search(r"\tscoped_guard\(mutex, &state->lock\) \{\n"
                  r"\t\tfor \(i = 0; i < 10; i\+\+\) \{\n"
                  r"\t\t\tret = regmap_read\(rdev->regmap, REG_PORTC, &data\);\n"
                  r".*?\treturn data & PC_RST_BRIDGE_N;", s, re.S)
    if not m:
        sys.exit("attiny: is_enabled anchor not found")
    s = (s[:m.start()] +
         "\t/*\n"
         "\t * Use the CACHED port state. Mainline reads PORTC back from the\n"
         "\t * chip, but this panel always returns 0x10 there, so a hardware\n"
         "\t * read reports \"disabled\" even when the panel is powered.\n"
         "\t */\n"
         "\t(void)ret; (void)i;\n"
         "\tguard(mutex)(&state->lock);\n"
         "\tdata = state->port_states[REG_PORTC - REG_PORTA];\n"
         "\treturn data & PC_RST_BRIDGE_N;" + s[m.end():])

    if "#include <linux/jiffies.h>" not in s:
        s = s.replace("#include <linux/module.h>",
                      "#include <linux/jiffies.h>\n#include <linux/module.h>", 1)

    open(p, "w").write(s)
    print("  attiny regulator: safe retries (no PORTC storm) + cached is_enabled")


if __name__ == "__main__":
    main()

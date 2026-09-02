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
       WRITE reg=0x83 val=0x0d ret=-110    (resets never released)
   Fixed by retrying against a short wall-clock deadline. In practice most
   writes now succeed first try and a few need two or three attempts.

2. is_enabled READS THE CHIP. Mainline reads PORTC back to decide whether the
   regulator is on. This panel always returns 0x10 for that register, so the
   regulator reports "disabled" while actually powered, which confuses the
   regulator core. Raspberry Pi's version uses the cached port state instead;
   we do the same.

Usage: patch-attiny-regulator.py <rpi-panel-attiny-regulator.c>
"""
import re
import sys

# Kept deliberately short. Most failing writes succeed on the second or third
# attempt, so a couple of seconds is ample. On the boots where the CCI bus is
# dead outright (see docs/TROUBLESHOOTING.md) no deadline helps, and a long one
# only stalls boot for a minute or more per write - the recovery service
# installed by scripts/35-install-recovery.sh picks those up instead.
RETRY_MS = 2000


def main():
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    p = sys.argv[1]
    s = open(p).read()

    if "uno-q-dsi-panel" in s:
        print("  attiny regulator already patched")
        return
    s = "/* patched by uno-q-dsi-panel */\n" + s

    # 1. retry port writes against a wall-clock deadline
    old = ("\tstate->port_states[reg - REG_PORTA] = val;\n"
           "\treturn regmap_write(state->regmap, reg, val);")
    if old not in s:
        sys.exit("attiny: set_port_state anchor not found")
    new = f"""\tint ret, i;
\tunsigned long deadline = jiffies + msecs_to_jiffies({RETRY_MS});

\tstate->port_states[reg - REG_PORTA] = val;

\t/*
\t * These writes intermittently time out on this board, most often on the
\t * PORTC transitions that assert PC_LED_EN and release the panel resets.
\t * The identical write succeeds a moment later, so retry rather than
\t * silently losing the panel.
\t */
\tfor (i = 0; ; i++) {{
\t\tret = regmap_write(state->regmap, reg, val);
\t\tif (!ret)
\t\t\tbreak;
\t\tif (time_after(jiffies, deadline))
\t\t\tbreak;
\t\tmsleep(50);
\t}}
\tif (ret)
\t\tpr_warn("attiny: write reg=0x%02x val=0x%02x failed after %d tries: %d\\n",
\t\t\treg, val, i + 1, ret);
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
    print("  attiny regulator: write retries + cached is_enabled")


if __name__ == "__main__":
    main()

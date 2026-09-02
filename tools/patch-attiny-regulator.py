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

# Deferred backlight re-assert. REG_PWM is the safe register - 0 failures in 32
# measured writes, and it never wedges the bus - and writing it alone is enough
# to light the panel. So when the backlight write is lost we simply keep trying
# in the background until it sticks.
#
# The deadline is generous because on a bad boot the bus can be disturbed for
# tens of seconds; the retry itself costs nothing.
PWM_RETRY_MS = 2000
PWM_DEADLINE_MS = 90000


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

    # 3. deferred backlight re-assert, using the register that never fails
    #
    # When the backlight write is lost the panel is dark while rendering a
    # perfectly good picture, and nothing in software can see it. Retrying
    # REG_PORTC to fix that is what wedges the bus - but REG_PWM is safe
    # (measured: 0 failures in 32 writes, never wedges), and writing it alone
    # is enough to light the panel. So on failure we keep re-asserting PWM
    # from a workqueue until it sticks.
    #
    # This is what removes the need for a userspace recovery service: the
    # panel comes back in seconds rather than ~38s.
    s = s.replace(
        "\tstruct gpio_chip gc;\n};",
        "\tstruct gpio_chip gc;\n\n"
        "\t/* deferred backlight re-assert; see attiny_pwm_retry_work() */\n"
        "\tstruct delayed_work pwm_work;\n"
        "\tstruct backlight_device *bl;\n"
        "\tunsigned long pwm_deadline;\n};", 1)

    work_fn = (
        "static void attiny_pwm_retry_work(struct work_struct *work)\n"
        "{\n"
        "\tstruct attiny_lcd *state = container_of(to_delayed_work(work),\n"
        "\t\t\t\t\t\tstruct attiny_lcd, pwm_work);\n"
        "\tint brightness, ret;\n"
        "\n"
        "\tif (!state->bl)\n"
        "\t\treturn;\n"
        "\n"
        "\t/*\n"
        "\t * props.brightness, not backlight_get_brightness(): we want the\n"
        "\t * brightness that was asked for, even if the device currently\n"
        "\t * reads as blanked.\n"
        "\t */\n"
        "\tbrightness = state->bl->props.brightness;\n"
        "\n"
        "\tscoped_guard(mutex, &state->lock)\n"
        "\t\tret = regmap_write(state->regmap, REG_PWM, brightness);\n"
        "\n"
        "\tif (!ret) {\n"
        "\t\tpr_info(\"attiny: backlight re-asserted (brightness %d)\\n\",\n"
        "\t\t\tbrightness);\n"
        "\t\treturn;\n"
        "\t}\n"
        "\n"
        "\tif (time_before(jiffies, state->pwm_deadline))\n"
        "\t\tschedule_delayed_work(&state->pwm_work,\n"
        "\t\t\t\t      msecs_to_jiffies(PWM_RETRY_MS));\n"
        "\telse\n"
        "\t\tpr_warn(\"attiny: backlight could not be re-asserted: %d\\n\",\n"
        "\t\t\tret);\n"
        "}\n"
        "\n"
        "static void attiny_cancel_pwm_work(void *data)\n"
        "{\n"
        "\tstruct attiny_lcd *state = data;\n"
        "\n"
        "\tcancel_delayed_work_sync(&state->pwm_work);\n"
        "}\n"
        "\n")
    anchor = "static int attiny_update_status(struct backlight_device *bl)"
    if anchor not in s:
        sys.exit("attiny: update_status anchor not found")
    s = s.replace(anchor, work_fn + anchor, 1)

    # On failure, arm the retry instead of just returning the error.
    old_us = ("\tfor (i = 0; i < 10; i++) {\n"
              "\t\tret = regmap_write(regmap, REG_PWM, brightness);\n"
              "\t\tif (!ret)\n"
              "\t\t\tbreak;\n"
              "\t}\n"
              "\n"
              "\treturn ret;")
    if old_us not in s:
        sys.exit("attiny: update_status body anchor not found")
    s = s.replace(old_us,
                  "\tfor (i = 0; i < 10; i++) {\n"
                  "\t\tret = regmap_write(regmap, REG_PWM, brightness);\n"
                  "\t\tif (!ret)\n"
                  "\t\t\tbreak;\n"
                  "\t}\n"
                  "\n"
                  "\t/*\n"
                  "\t * A lost write here means a dark panel that every\n"
                  "\t * software check still reports as healthy, so keep\n"
                  "\t * trying in the background rather than giving up.\n"
                  "\t */\n"
                  "\tif (ret) {\n"
                  f"\t\tstate->pwm_deadline = jiffies + msecs_to_jiffies({PWM_DEADLINE_MS});\n"
                  "\t\tschedule_delayed_work(&state->pwm_work,\n"
                  f"\t\t\t\t      msecs_to_jiffies({PWM_RETRY_MS}));\n"
                  "\t}\n"
                  "\n"
                  "\treturn ret;", 1)

    # Wire it up in probe, and make sure it cannot outlive the device.
    old_probe = "\tbl->props.brightness = 0xff;\n"
    if old_probe not in s:
        sys.exit("attiny: probe backlight anchor not found")
    s = s.replace(old_probe,
                  "\tbl->props.brightness = 0xff;\n"
                  "\n"
                  "\tstate->bl = bl;\n"
                  "\tINIT_DELAYED_WORK(&state->pwm_work, attiny_pwm_retry_work);\n"
                  "\tret = devm_add_action_or_reset(&i2c->dev,\n"
                  "\t\t\t\t       attiny_cancel_pwm_work, state);\n"
                  "\tif (ret)\n"
                  "\t\treturn ret;\n", 1)

    s = s.replace("#define REG_ID\t\t0x80",
                  f"#define PWM_RETRY_MS\t\t{PWM_RETRY_MS}\n"
                  f"#define PWM_DEADLINE_MS\t\t{PWM_DEADLINE_MS}\n\n"
                  "#define REG_ID\t\t0x80", 1)

    for hdr in ("#include <linux/jiffies.h>", "#include <linux/workqueue.h>"):
        if hdr not in s:
            s = s.replace("#include <linux/module.h>",
                          hdr + "\n#include <linux/module.h>", 1)

    open(p, "w").write(s)
    print("  attiny regulator: safe retries (no PORTC storm) + cached is_enabled")


if __name__ == "__main__":
    main()

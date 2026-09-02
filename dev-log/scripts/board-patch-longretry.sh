#!/bin/sh
# Runs ON the UNO Q. Stdin secrets contract: 1. sudo password  2. SSID  3. wifi pw
#
# Observed on three consecutive boots: switching on the panel's main power rail
# (PORTB = PB_LCD_MAIN) disturbs the ATTINY's I2C for ~35 seconds. Our retry loop
# only spans ~10s, so it gives up and tc358762_init() then configures a bridge
# that is still held in reset:
#
#    8.043  WRITE 0x82=0x80  ret=0        <- panel power ON
#   27.362  WRITE 0x83=0x0d  ret=-110     <- reset release FAILS
#   27.915  tc358762-dbg: init ...        <- bridge configured while in reset
#   43.237  WRITE 0x83=0x0d  ret=0        <- reset released 15s too late
#
# Fix: retry on a WALL-CLOCK deadline long enough to outlast the disturbance,
# so the reset is released before init runs.
unset HISTFILE
IFS= read -r SUDO_PASS; SUDO_PASS=$(printf '%s' "$SUDO_PASS" | tr -d '\r')
IFS= read -r WIFI_SSID
IFS= read -r WIFI_PASS
S() { printf '%s\n' "$SUDO_PASS" | sudo -S -p '' "$@"; }
S true 2>/dev/null || { echo "SUDO PASSWORD REJECTED"; exit 1; }

cd "$HOME/panel-build" || exit 1
K=$(uname -r)

python3 - <<'PY'
p = 'rpi-panel-attiny-regulator.c'
s = open(p).read()

old_start = "\tint dbg_ret, dbg_i;"
assert old_start in s, "expected the previously patched retry loop"

# replace the whole retry block with a wall-clock deadline version
import re
old = re.search(r"\tint dbg_ret, dbg_i;.*?\treturn dbg_ret;", s, re.S).group(0)
new = """\tint dbg_ret, dbg_i;
\tunsigned long dbg_deadline = jiffies + msecs_to_jiffies(75000);

\tstate->port_states[reg - REG_PORTA] = val;

\t/* Switching PB_LCD_MAIN on disturbs this chip's I2C for ~35s. Retry on a
\t * wall-clock deadline so the caller does not proceed with a bridge that is
\t * still held in reset.
\t */
\tfor (dbg_i = 0; ; dbg_i++) {
\t\tdbg_ret = regmap_write(state->regmap, reg, val);
\t\tif (!dbg_ret)
\t\t\tbreak;
\t\tif (time_after(jiffies, dbg_deadline))
\t\t\tbreak;
\t\tmsleep(50);
\t}
\tpr_info("attiny-dbg: WRITE reg=0x%02x val=0x%02x ret=%d attempts=%d\\n",
\t\treg, val, dbg_ret, dbg_i + 1);
\treturn dbg_ret;"""
s = s.replace(old, new, 1)

if '#include <linux/jiffies.h>' not in s:
    s = s.replace('#include <linux/module.h>',
                  '#include <linux/jiffies.h>\n#include <linux/module.h>', 1)

open(p, 'w').write(s)
print("patched: port writes now retry against a 75s wall-clock deadline")
PY

echo
echo "=== verify ==="
grep -n -A6 "dbg_deadline" rpi-panel-attiny-regulator.c | head -20

echo
echo "=== rebuild ==="
make -C "/lib/modules/$K/build" M="$PWD" modules 2>&1 | tail -6
ls -la rpi-panel-attiny-regulator.ko

echo
echo "=== install ==="
S cp rpi-panel-attiny-regulator.ko "/lib/modules/$K/extra/"
S depmod -a

echo
echo "=== rebooting in 3s (boot will be SLOW - up to ~75s stalled in the retry) ==="
S nohup sh -c 'sleep 3; systemctl reboot' >/dev/null 2>&1 &
sleep 1
echo "reboot scheduled"

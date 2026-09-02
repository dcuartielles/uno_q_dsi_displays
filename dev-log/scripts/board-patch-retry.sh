#!/bin/sh
# Runs ON the UNO Q. Stdin secrets contract: 1. sudo password  2. SSID  3. wifi pw
#
# THE FIX (evidence-driven):
#
#   WRITE port reg=0x83 val=0x01 ret=-110   <- PC_LED_EN never asserted
#   WRITE port reg=0x83 val=0x0d ret=-110   <- bridge/LCD reset never released
#   BACKLIGHT ret=-110 attempts=11 ... then ret=0 attempts=1 a second later
#
# The port writes that actually matter time out, and attiny_set_port_state()
# does not retry - it ignores the return code entirely. The identical write
# succeeds moments later, so this is transient, not fatal.
#
# Patch: retry every port write (up to ~3s), and make the backlight retry
# loop sleep between attempts instead of spinning.
unset HISTFILE
IFS= read -r SUDO_PASS; SUDO_PASS=$(printf '%s' "$SUDO_PASS" | tr -d '\r')
IFS= read -r WIFI_SSID
IFS= read -r WIFI_PASS
S() { printf '%s\n' "$SUDO_PASS" | sudo -S -p '' "$@"; }
S true 2>/dev/null || { echo "SUDO PASSWORD REJECTED"; exit 1; }

cd "$HOME/panel-build" || exit 1
K=$(uname -r)
cp rpi-panel-attiny-regulator.c.orig rpi-panel-attiny-regulator.c

python3 - <<'PY'
p = 'rpi-panel-attiny-regulator.c'
s = open(p).read()

# --- retry port writes, with logging ---
old = """	state->port_states[reg - REG_PORTA] = val;
	return regmap_write(state->regmap, reg, val);"""
new = """	int dbg_ret, dbg_i;

	state->port_states[reg - REG_PORTA] = val;

	/* The panel MCU intermittently NAKs/stalls these writes (-ETIMEDOUT),
	 * most reliably on the PORTC transitions that assert PC_LED_EN and
	 * release the bridge/LCD resets. The identical write succeeds a moment
	 * later, so retry rather than silently losing the panel.
	 */
	for (dbg_i = 0; dbg_i < 60; dbg_i++) {
		dbg_ret = regmap_write(state->regmap, reg, val);
		if (!dbg_ret)
			break;
		msleep(50);
	}
	pr_info("attiny-dbg: WRITE port reg=0x%02x val=0x%02x ret=%d attempts=%d\\n",
		reg, val, dbg_ret, dbg_i + 1);
	return dbg_ret;"""
assert old in s, "port_state anchor missing"
s = s.replace(old, new)

# --- backlight: sleep between retries, and retry for longer ---
old = """	for (i = 0; i < 10; i++) {
		ret = regmap_write(regmap, REG_PWM, brightness);
		if (!ret)
			break;
	}

	return ret;"""
new = """	for (i = 0; i < 60; i++) {
		ret = regmap_write(regmap, REG_PWM, brightness);
		if (!ret)
			break;
		msleep(50);
	}
	pr_info("attiny-dbg: BACKLIGHT brightness=%d ret=%d attempts=%d\\n",
		brightness, ret, i + 1);
	return ret;"""
assert old in s
s = s.replace(old, new)

# --- keep the sequence markers so we can read the trace ---
old = """	/* Ensure bridge, and tp stay in reset */
	attiny_set_port_state(state, REG_PORTC, 0);"""
new = """	pr_info("attiny-dbg: >>> power_enable ENTER\\n");
	/* Ensure bridge, and tp stay in reset */
	attiny_set_port_state(state, REG_PORTC, 0);"""
assert old in s
s = s.replace(old, new)

old = """	attiny_set_port_state(state, REG_PORTC, PC_LED_EN);

	msleep(80);

	return 0;"""
new = """	attiny_set_port_state(state, REG_PORTC, PC_LED_EN);

	msleep(80);
	pr_info("attiny-dbg: <<< power_enable EXIT\\n");
	return 0;"""
assert old in s
s = s.replace(old, new)

old = """static int attiny_gpio_set(struct gpio_chip *gc, unsigned int off, int val)
{
	struct attiny_lcd *state = gpiochip_get_data(gc);
	u8 last_val;"""
new = """static int attiny_gpio_set(struct gpio_chip *gc, unsigned int off, int val)
{
	struct attiny_lcd *state = gpiochip_get_data(gc);
	u8 last_val;

	pr_info("attiny-dbg: GPIO set line=%u val=%d\\n", off, val);"""
assert old in s
s = s.replace(old, new)

open(p, 'w').write(s)
print("patched OK (retries added)")
PY

echo
echo "=== rebuild ==="
make -C "/lib/modules/$K/build" M="$PWD" modules 2>&1 | tail -6
ls -la rpi-panel-attiny-regulator.ko

echo
echo "=== install ==="
S cp rpi-panel-attiny-regulator.ko "/lib/modules/$K/extra/"
S depmod -a

echo
echo "=== rebooting in 3s ==="
S nohup sh -c 'sleep 3; systemctl reboot' >/dev/null 2>&1 &
sleep 1
echo "reboot scheduled"

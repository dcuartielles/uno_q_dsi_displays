#!/bin/sh
# Runs ON the UNO Q. Stdin secrets contract: 1. sudo password  2. SSID  3. wifi pw
#
# Instrument rpi-panel-attiny-regulator so we can finally see whether its I2C
# writes actually succeed. The stock driver ignores every regmap_write() return
# code, which is why we have no ground truth.
unset HISTFILE
IFS= read -r SUDO_PASS; SUDO_PASS=$(printf '%s' "$SUDO_PASS" | tr -d '\r')
IFS= read -r WIFI_SSID
IFS= read -r WIFI_PASS
S() { printf '%s\n' "$SUDO_PASS" | sudo -S -p '' "$@"; }
S true 2>/dev/null || { echo "SUDO PASSWORD REJECTED"; exit 1; }

cd "$HOME/panel-build" || exit 1
K=$(uname -r)
[ -f rpi-panel-attiny-regulator.c.orig ] || cp rpi-panel-attiny-regulator.c rpi-panel-attiny-regulator.c.orig
cp rpi-panel-attiny-regulator.c.orig rpi-panel-attiny-regulator.c

python3 - <<'PY'
import re
p = 'rpi-panel-attiny-regulator.c'
s = open(p).read()

# 1. log every port write and its return code
old = """	state->port_states[reg - REG_PORTA] = val;
	return regmap_write(state->regmap, reg, val);"""
new = """	int dbg_ret;
	state->port_states[reg - REG_PORTA] = val;
	dbg_ret = regmap_write(state->regmap, reg, val);
	pr_info("attiny-dbg: WRITE port reg=0x%02x val=0x%02x ret=%d\\n", reg, val, dbg_ret);
	return dbg_ret;"""
assert old in s, "port_state anchor missing"
s = s.replace(old, new)

# 2. mark the power-on sequence
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

# 3. log backlight writes
old = """	for (i = 0; i < 10; i++) {
		ret = regmap_write(regmap, REG_PWM, brightness);
		if (!ret)
			break;
	}

	return ret;"""
new = """	for (i = 0; i < 10; i++) {
		ret = regmap_write(regmap, REG_PWM, brightness);
		if (!ret)
			break;
	}
	pr_info("attiny-dbg: BACKLIGHT brightness=%d ret=%d attempts=%d\\n",
		brightness, ret, i + 1);
	return ret;"""
assert old in s
s = s.replace(old, new)

# 4. log is_enabled's readback
old = """	if (ret < 0)
		return ret;

	return data & PC_RST_BRIDGE_N;"""
new = """	if (ret < 0) {
		pr_info("attiny-dbg: is_enabled READ FAILED ret=%d\\n", ret);
		return ret;
	}
	pr_info("attiny-dbg: is_enabled PORTC=0x%02x -> %d\\n",
		data, !!(data & PC_RST_BRIDGE_N));
	return data & PC_RST_BRIDGE_N;"""
assert old in s
s = s.replace(old, new)

# 5. log the gpio set path (this is what releases the bridge reset)
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
print("patched OK")
PY

echo
echo "=== rebuild ==="
make -C "/lib/modules/$K/build" M="$PWD" modules 2>&1 | tail -8
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

#!/bin/sh
# Runs ON the UNO Q. Stdin secrets contract: 1. sudo password  2. SSID  3. wifi pw
#
# Backport Raspberry Pi's POLLING path into mainline edt-ft5x06.
#
# Mainline requires a hardware interrupt and fails with -EINVAL when there is
# none. The UNO Media Carrier's DSI connector has no touch IRQ (pins 17/18 are
# NC), so the driver can never probe. RPi added a 60fps poll timer for exactly
# this case; their DT for this panel has no interrupt either.
unset HISTFILE
IFS= read -r SUDO_PASS; SUDO_PASS=$(printf '%s' "$SUDO_PASS" | tr -d '\r')
IFS= read -r WIFI_SSID
IFS= read -r WIFI_PASS
S() { printf '%s\n' "$SUDO_PASS" | sudo -S -p '' "$@"; }
S true 2>/dev/null || { echo "SUDO PASSWORD REJECTED"; exit 1; }

K=$(uname -r)
SRC="$HOME/panel-build"
cd "$SRC" || exit 1
[ -s edt-ft5x06.c ] || cp "$HOME/driver-compare/mainline/edt-ft5x06.c" .
[ -s edt-ft5x06.c.orig ] || cp edt-ft5x06.c edt-ft5x06.c.orig
cp edt-ft5x06.c.orig edt-ft5x06.c

python3 - <<'PY'
p = 'edt-ft5x06.c'
s = open(p).read()

# 1. polling interval defines
anchor = '#define EDT_SWITCH_MODE_RETRIES'
assert anchor in s
s = s.replace(anchor,
    '#define FIRST_POLL_DELAY_MS\t\t300\t/* extra settle before first poll */\n'
    '#define POLL_INTERVAL_MS\t\t17\t/* 17ms = 60fps */\n\n' + anchor, 1)

# 2. struct fields
old = '\tunsigned int crc_errors;\n\tunsigned int header_errors;\n'
assert old in s, "struct anchor missing"
s = s.replace(old, old + '\n\tstruct timer_list timer;\n\tstruct work_struct work_i2c_poll;\n', 1)

# 3. the poll timer + work, placed right after the ISR
anchor = 'struct edt_ft5x06_attribute {'
assert anchor in s
poll = '''static void edt_ft5x06_ts_irq_poll_timer(struct timer_list *t)
{
\tstruct edt_ft5x06_ts_data *tsdata = timer_container_of(tsdata, t, timer);

\tschedule_work(&tsdata->work_i2c_poll);
\tmod_timer(&tsdata->timer, jiffies + msecs_to_jiffies(POLL_INTERVAL_MS));
}

static void edt_ft5x06_ts_work_i2c_poll(struct work_struct *work)
{
\tstruct edt_ft5x06_ts_data *tsdata = container_of(work,
\t\t\tstruct edt_ft5x06_ts_data, work_i2c_poll);

\tedt_ft5x06_ts_isr(0, tsdata);
}

'''
s = s.replace(anchor, poll + anchor, 1)

# 4. probe: poll when there is no IRQ, instead of failing
old = '''	error = devm_request_threaded_irq(&client->dev, client->irq,
					  NULL, edt_ft5x06_ts_isr, irq_flags,
					  client->name, tsdata);
	if (error) {
		dev_err(&client->dev, "Unable to request touchscreen IRQ.\\n");
		return error;
	}
'''
new = '''	if (client->irq > 0) {
		error = devm_request_threaded_irq(&client->dev, client->irq,
						  NULL, edt_ft5x06_ts_isr,
						  irq_flags, client->name,
						  tsdata);
		if (error) {
			dev_err(&client->dev,
				"Unable to request touchscreen IRQ.\\n");
			return error;
		}
	} else {
		/*
		 * No interrupt line (the UNO Media Carrier's DSI connector has
		 * none). Poll at 60fps, as the Raspberry Pi driver does.
		 */
		dev_info(&client->dev,
			 "no IRQ, polling every %d ms\\n", POLL_INTERVAL_MS);
		INIT_WORK(&tsdata->work_i2c_poll,
			  edt_ft5x06_ts_work_i2c_poll);
		timer_setup(&tsdata->timer, edt_ft5x06_ts_irq_poll_timer, 0);
		tsdata->timer.expires =
			jiffies + msecs_to_jiffies(FIRST_POLL_DELAY_MS);
		add_timer(&tsdata->timer);
	}
'''
assert old in s, "probe irq anchor missing"
s = s.replace(old, new, 1)

# 5. teardown
old = 'static void edt_ft5x06_ts_remove(struct i2c_client *client)\n{\n'
assert old in s, "remove anchor missing"
new = old + ('\tstruct edt_ft5x06_ts_data *poll_tsdata = i2c_get_clientdata(client);\n\n'
             '\tif (client->irq <= 0) {\n'
             '\t\ttimer_delete_sync(&poll_tsdata->timer);\n'
             '\t\tcancel_work_sync(&poll_tsdata->work_i2c_poll);\n'
             '\t}\n\n')
s = s.replace(old, new, 1)

open(p, 'w').write(s)
print("patched edt-ft5x06.c: polling fallback added")
PY

echo
echo "=== verify ==="
grep -n 'POLL_INTERVAL_MS\|no IRQ, polling\|work_i2c_poll' edt-ft5x06.c | head

echo
echo "=== build ==="
grep -q 'edt-ft5x06' Makefile || sed -i '1i obj-m += edt-ft5x06.o' Makefile
make -C "/lib/modules/$K/build" M="$PWD" modules 2>&1 | tail -14
ls -la edt-ft5x06.ko 2>/dev/null || { echo ">>> BUILD FAILED"; exit 1; }

echo
echo "=== install (in-tree original saved as .distrib) ==="
INTREE="/lib/modules/$K/kernel/drivers/input/touchscreen/edt-ft5x06.ko"
S sh -c "[ -f '$INTREE.distrib' ] || cp '$INTREE' '$INTREE.distrib'"
S cp edt-ft5x06.ko "$INTREE"
S depmod -a

echo
echo "=== reload and see if it probes now ==="
S modprobe -r edt_ft5x06 2>/dev/null
S modprobe edt_ft5x06 2>&1
sleep 2
dmesg | grep -iE 'edt_ft5|ft5506' | tail -6
echo "--- input devices ---"
grep -iE 'Name=|Handlers=' /proc/bus/input/devices | sed 's/^/  /'

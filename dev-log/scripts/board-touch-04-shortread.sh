#!/bin/sh
# Runs ON the UNO Q. Stdin secrets contract: 1. sudo password  2. SSID  3. wifi pw
#
# Mainline's ISR does ONE regmap_bulk_read of tdata_len bytes
#   tdata_len = point_len(6) * max_support_points + tdata_offset(3)  = 33..63
# which fails with -6 on the Qualcomm CCI I2C controller. Confirmed from
# userspace earlier: an 8-byte read works, a 32-byte read fails.
#
# Fix (following RPi's staged approach, but shortening the FIRST read too):
#   1. read only the 3-byte header  -> TD_STATUS tells us how many contacts
#   2. read only point_len * num_points bytes for those contacts
# so no transfer exceeds a handful of bytes.
#
# Also brings across RPi's released-id tracking and the stale-data filter,
# both of which matter when polling rather than using an interrupt.
unset HISTFILE
IFS= read -r SUDO_PASS; SUDO_PASS=$(printf '%s' "$SUDO_PASS" | tr -d '\r')
IFS= read -r WIFI_SSID
IFS= read -r WIFI_PASS
S() { printf '%s\n' "$SUDO_PASS" | sudo -S -p '' "$@"; }
S true 2>/dev/null || { echo "SUDO PASSWORD REJECTED"; exit 1; }

K=$(uname -r)
cd "$HOME/panel-build" || exit 1

python3 - <<'PY'
p = 'edt-ft5x06.c'
s = open(p).read()

# --- struct fields for release tracking and the stale-data filter ---
old = '\n\tstruct timer_list timer;\n'
assert old in s, "polling struct fields missing - run the polling patch first"
s = s.replace(old, '\n\tunsigned int known_ids;\n\tint init_td_status;\n\n\tstruct timer_list timer;\n', 1)

# --- replace the ISR body: short header read, then only the reported points ---
old = '''	u8 rdbuf[63];
	int i, type, x, y, id;
	int error;

	memset(rdbuf, 0, sizeof(rdbuf));
	error = regmap_bulk_read(tsdata->regmap, tsdata->tdata_cmd, rdbuf,
				 tsdata->tdata_len);
	if (error) {
		dev_err_ratelimited(dev, "Unable to fetch data, error: %d\\n",
				    error);
		goto out;
	}

	for (i = 0; i < tsdata->max_support_points; i++) {'''
new = '''	u8 rdbuf[63];
	int i, type, x, y, id;
	int error;
	int num_points;
	unsigned int active_ids = 0, known_ids = tsdata->known_ids;
	long released_ids;
	int b = 0;

	memset(rdbuf, 0, sizeof(rdbuf));

	if (tsdata->version == EDT_M06) {
		error = regmap_bulk_read(tsdata->regmap, tsdata->tdata_cmd,
					 rdbuf, tsdata->tdata_len);
		num_points = tsdata->max_support_points;
	} else {
		/*
		 * Read only the short header first. A full tdata_len read
		 * (33-63 bytes) fails with -ENXIO on the Qualcomm CCI I2C
		 * controller, which cannot do long transfers.
		 */
		error = regmap_bulk_read(tsdata->regmap, tsdata->tdata_cmd,
					 rdbuf, tsdata->tdata_offset);

		/* register 2 is TD_STATUS: the number of active contacts */
		num_points = min(rdbuf[2] & 0xf, tsdata->max_support_points);

		/*
		 * When polling without an IRQ the initial register contents
		 * can be stale; discard readings until TD_STATUS first changes.
		 */
		if (tsdata->init_td_status) {
			if (tsdata->init_td_status < 0)
				tsdata->init_td_status = rdbuf[2];

			if (num_points && rdbuf[2] == tsdata->init_td_status)
				goto out;

			tsdata->init_td_status = 0;
		}

		/* now fetch just the points that are actually reported */
		if (!error && num_points)
			error = regmap_bulk_read(tsdata->regmap,
						 tsdata->tdata_offset,
						 &rdbuf[tsdata->tdata_offset],
						 tsdata->point_len * num_points);
	}

	if (error) {
		dev_err_ratelimited(dev, "Unable to fetch data, error: %d\\n",
				    error);
		goto out;
	}

	for (i = 0; i < num_points; i++) {'''
assert old in s, "ISR head anchor missing"
s = s.replace(old, new, 1)

# --- track released contacts (TOUCH_UP is not always reported) ---
old = '''		input_mt_slot(tsdata->input, id);
		if (input_mt_report_slot_state(tsdata->input, MT_TOOL_FINGER,
					       type != TOUCH_EVENT_UP))
			touchscreen_report_pos(tsdata->input, &tsdata->prop,
					       x, y, true);
	}

	input_mt_report_pointer_emulation(tsdata->input, true);'''
new = '''		input_mt_slot(tsdata->input, id);
		if (input_mt_report_slot_state(tsdata->input, MT_TOOL_FINGER,
					       type != TOUCH_EVENT_UP)) {
			touchscreen_report_pos(tsdata->input, &tsdata->prop,
					       x, y, true);
			active_ids |= BIT(id);
		} else {
			known_ids &= ~BIT(id);
		}
	}

	/*
	 * TOUCH_UP is not always reported, so track which ids we have seen
	 * and release the ones that stopped being updated.
	 */
	released_ids = known_ids & ~active_ids;
	for_each_set_bit_from(b, &released_ids, tsdata->max_support_points) {
		input_mt_slot(tsdata->input, b);
		input_mt_report_slot_inactive(tsdata->input);
	}
	tsdata->known_ids = active_ids;

	input_mt_report_pointer_emulation(tsdata->input, true);'''
assert old in s, "ISR tail anchor missing"
s = s.replace(old, new, 1)

# --- arm the stale-data filter when we are polling ---
old = '\t\tINIT_WORK(&tsdata->work_i2c_poll,\n'
assert old in s
s = s.replace(old, '\t\ttsdata->init_td_status = -1; /* filter bogus initial data */\n' + old, 1)

open(p, 'w').write(s)
print("patched edt-ft5x06.c: short header read + staged point read")
PY

echo
echo "=== build ==="
make -C "/lib/modules/$K/build" M="$PWD" modules 2>&1 | tail -10
ls -la edt-ft5x06.ko || { echo ">>> BUILD FAILED"; exit 1; }

echo
echo "=== install + reload ==="
INTREE="/lib/modules/$K/kernel/drivers/input/touchscreen/edt-ft5x06.ko"
S cp edt-ft5x06.ko "$INTREE"
S depmod -a
S modprobe -r edt_ft5x06 2>/dev/null
S dmesg -C
S modprobe edt_ft5x06 2>&1
sleep 3

echo
echo "=== driver messages ==="
dmesg | grep -iE 'edt_ft5|ft5506' | head -10

echo
echo "=== input devices ==="
grep -iE 'Name=|Handlers=' /proc/bus/input/devices | sed 's/^/  /'

DEV=$(grep -A5 'ft5x06' /proc/bus/input/devices | grep -o 'event[0-9]*' | head -1)
echo
echo "*** TOUCH AND DRAG ON THE PANEL FOR 20 SECONDS (device /dev/input/$DEV) ***"
S timeout 20 evtest "/dev/input/$DEV" 2>/dev/null > /tmp/t.log
echo "  events captured: $(grep -c '^Event: time' /tmp/t.log)"
grep '^Event: time' /tmp/t.log | head -20

echo
echo "=== read errors during the test ==="
dmesg | grep -c 'Unable to fetch data'

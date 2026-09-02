#!/usr/bin/env python3
"""Make mainline's edt-ft5x06 touch driver work on the UNO Media Carrier.

Two independent problems, both fatal on this hardware:

1. NO INTERRUPT. The carrier's DSI connector has no touch IRQ line (pins 17
   and 18 are NC), and mainline hard-requires one:
       edt_ft5x06 0-0038: Unable to request touchscreen IRQ.
       probe with driver edt_ft5x06 failed with error -22
   Raspberry Pi's version polls at 60fps instead; their device tree for these
   panels has no interrupt either. Backported here.

2. LONG I2C READS FAIL. Mainline issues one regmap_bulk_read of
       tdata_len = point_len * max_support_points + tdata_offset   (33..63 bytes)
   which returns -ENXIO on the Qualcomm CCI I2C controller - it cannot do long
   transfers. (Reproducible from userspace: an 8-byte read succeeds, a 32-byte
   read fails.) Fixed by reading the 3-byte header first, taking the contact
   count from TD_STATUS, then fetching only those points.

3. IDENTIFICATION IS NOT RETRIED. edt_ft5x06_ts_identify() is the first I2C
   traffic to the controller and mainline gives up on the first error:
       edt_ft5x06 2-0038: touchscreen probe failed
       probe with driver edt_ft5x06 failed with error -110
   On this board it runs while the panel controller at 0x45 is still retrying
   its own writes, and the CCI bus can be flaky for the first seconds after
   boot - so a single -ETIMEDOUT loses the touchscreen for the whole session,
   even though the very same driver probes fine a moment later. Retried here
   against a wall-clock deadline, pulsing the controller's reset in between.

Also brings across RPi's released-contact tracking, since the controller does
not reliably report TOUCH_UP - without it, contacts stick.

Usage: patch-edt-ft5x06.py <edt-ft5x06.c>
"""
import sys

IDENTIFY_RETRY_MS = 10000

POLL_FNS = """static void edt_ft5x06_ts_irq_poll_timer(struct timer_list *t)
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

"""


def sub(s, old, new, what):
    if old not in s:
        sys.exit("edt-ft5x06: anchor not found (%s) - kernel source differs "
                 "from what this patch expects" % what)
    return s.replace(old, new, 1)


def main():
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    p = sys.argv[1]
    s = open(p).read()

    if "uno-q-dsi-panel" in s:
        print("  edt-ft5x06 already patched")
        return

    s = "/* patched by uno-q-dsi-panel */\n" + s

    # 1. polling intervals
    s = sub(s, "#define EDT_SWITCH_MODE_RETRIES",
            "#define FIRST_POLL_DELAY_MS\t\t300\t/* settle before first poll */\n"
            "#define POLL_INTERVAL_MS\t\t17\t/* 17ms = 60fps */\n"
            f"#define EDT_IDENTIFY_RETRY_MS\t\t{IDENTIFY_RETRY_MS}\n\n"
            "#define EDT_SWITCH_MODE_RETRIES", "poll defines")

    # 2. state for polling and release tracking
    s = sub(s, "\tunsigned int crc_errors;\n\tunsigned int header_errors;\n",
            "\tunsigned int crc_errors;\n\tunsigned int header_errors;\n\n"
            "\tunsigned int known_ids;\n\tint init_td_status;\n"
            "\tstruct timer_list timer;\n\tstruct work_struct work_i2c_poll;\n",
            "struct fields")

    # 3. poll timer + work, right after the ISR
    s = sub(s, "struct edt_ft5x06_attribute {",
            POLL_FNS + "struct edt_ft5x06_attribute {", "poll functions")

    # 4. ISR: short header read, then only the reported points
    s = sub(s, """	u8 rdbuf[63];
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

	for (i = 0; i < tsdata->max_support_points; i++) {""",
            """	u8 rdbuf[63];
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
		 * Read only the short header. A full tdata_len read (33-63
		 * bytes) returns -ENXIO on the Qualcomm CCI I2C controller,
		 * which cannot do long transfers.
		 */
		error = regmap_bulk_read(tsdata->regmap, tsdata->tdata_cmd,
					 rdbuf, tsdata->tdata_offset);

		/* register 2 is TD_STATUS: number of active contacts */
		num_points = min(rdbuf[2] & 0xf, tsdata->max_support_points);

		/*
		 * When polling, the initial register contents may be stale;
		 * discard readings until TD_STATUS first changes.
		 */
		if (tsdata->init_td_status) {
			if (tsdata->init_td_status < 0)
				tsdata->init_td_status = rdbuf[2];

			if (num_points && rdbuf[2] == tsdata->init_td_status)
				goto out;

			tsdata->init_td_status = 0;
		}

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

	for (i = 0; i < num_points; i++) {""", "ISR head")

    # 5. release contacts that stop being reported
    s = sub(s, """		input_mt_slot(tsdata->input, id);
		if (input_mt_report_slot_state(tsdata->input, MT_TOOL_FINGER,
					       type != TOUCH_EVENT_UP))
			touchscreen_report_pos(tsdata->input, &tsdata->prop,
					       x, y, true);
	}

	input_mt_report_pointer_emulation(tsdata->input, true);""",
            """		input_mt_slot(tsdata->input, id);
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
	 * TOUCH_UP is not always reported, so track the ids we have seen and
	 * release those that stopped being updated.
	 */
	released_ids = known_ids & ~active_ids;
	for_each_set_bit_from(b, &released_ids, tsdata->max_support_points) {
		input_mt_slot(tsdata->input, b);
		input_mt_report_slot_inactive(tsdata->input);
	}
	tsdata->known_ids = active_ids;

	input_mt_report_pointer_emulation(tsdata->input, true);""", "ISR tail")

    # 6. probe: retry identification on a flaky bus instead of giving up
    s = sub(s, """	error = edt_ft5x06_ts_identify(client, tsdata);
	if (error) {
		dev_err(&client->dev, "touchscreen probe failed\\n");
		return error;
	}
""",
            """	/*
	 * This is the first I2C traffic to the controller. On this board it
	 * runs while the panel controller at 0x45 is still retrying its own
	 * writes, and the CCI bus can be flaky for the first seconds after
	 * boot - so a single -ETIMEDOUT here would lose the touchscreen for
	 * the whole session even though probing succeeds moments later.
	 * Retry against a wall-clock deadline, pulsing reset in between.
	 */
	{
		unsigned long deadline =
			jiffies + msecs_to_jiffies(EDT_IDENTIFY_RETRY_MS);
		int tries = 0;

		for (;;) {
			error = edt_ft5x06_ts_identify(client, tsdata);
			if (!error)
				break;
			tries++;
			if (time_after(jiffies, deadline)) {
				dev_err(&client->dev,
					"touchscreen probe failed after %d tries: %d\\n",
					tries, error);
				return error;
			}
			if (tsdata->reset_gpio) {
				gpiod_set_value_cansleep(tsdata->reset_gpio, 1);
				usleep_range(5000, 6000);
				gpiod_set_value_cansleep(tsdata->reset_gpio, 0);
				msleep(300);
			} else {
				msleep(200);
			}
		}
		if (tries)
			dev_info(&client->dev,
				 "identified after %d retr%s\\n",
				 tries, tries == 1 ? "y" : "ies");
	}
""", "probe identify")

    # 7. probe: poll when there is no interrupt
    s = sub(s, """	error = devm_request_threaded_irq(&client->dev, client->irq,
					  NULL, edt_ft5x06_ts_isr, irq_flags,
					  client->name, tsdata);
	if (error) {
		dev_err(&client->dev, "Unable to request touchscreen IRQ.\\n");
		return error;
	}
""",
            """	if (client->irq > 0) {
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
		dev_info(&client->dev, "no IRQ, polling every %d ms\\n",
			 POLL_INTERVAL_MS);
		tsdata->init_td_status = -1; /* filter bogus initial data */
		INIT_WORK(&tsdata->work_i2c_poll,
			  edt_ft5x06_ts_work_i2c_poll);
		timer_setup(&tsdata->timer, edt_ft5x06_ts_irq_poll_timer, 0);
		tsdata->timer.expires =
			jiffies + msecs_to_jiffies(FIRST_POLL_DELAY_MS);
		add_timer(&tsdata->timer);
	}
""", "probe irq")

    # 8. teardown
    s = sub(s, "static void edt_ft5x06_ts_remove(struct i2c_client *client)\n{\n",
            "static void edt_ft5x06_ts_remove(struct i2c_client *client)\n{\n"
            "\tstruct edt_ft5x06_ts_data *poll_tsdata = i2c_get_clientdata(client);\n\n"
            "\tif (client->irq <= 0) {\n"
            "\t\ttimer_delete_sync(&poll_tsdata->timer);\n"
            "\t\tcancel_work_sync(&poll_tsdata->work_i2c_poll);\n"
            "\t}\n\n", "remove")

    if "#include <linux/jiffies.h>" not in s:
        s = s.replace("#include <linux/module.h>",
                      "#include <linux/jiffies.h>\n#include <linux/module.h>", 1)

    open(p, "w").write(s)
    print("  edt-ft5x06: polling + short I2C reads + probe retry")


if __name__ == "__main__":
    main()

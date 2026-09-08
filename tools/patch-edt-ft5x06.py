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
   even though the very same driver probes fine a moment later.

   Retried here in TWO stages, because the length of the retry and the cost of
   holding the bus pull in opposite directions:

     a) a short synchronous window, for an ordinary transient hiccup; then
     b) if that fails, probe SUCCEEDS anyway and the rest of bring-up moves to
        a delayed work item that retries every few seconds until a deadline.

   Stage (b) is the point. Measured on a Waveshare panel: the CCI bus is wedged
   for the first ~100 s of a boot (176 timeouts), far longer than any
   synchronous window that does not also starve the panel controller of the
   bus it needs to turn the backlight on. Spinning is what does the damage, not
   waiting - so between attempts the driver holds nothing at all.

Also brings across RPi's released-contact tracking, since the controller does
not reliably report TOUCH_UP - without it, contacts stick.

Usage: patch-edt-ft5x06.py <edt-ft5x06.c>
"""
import sys

# Stage (a): the synchronous window, kept SHORT, and this was measured the hard
# way.
#
# Reads are individually safe - they never wedge the bus - so a long retry
# window looked free. It is not. Stretching it to 40s made things worse on both
# counts: touch went from 1-in-4 missing to 3-in-6, and the panel controller's
# backlight re-assert slipped from 11.7s to ~54s, because it could not get a
# word in until the touch driver finally gave up. Safe in isolation is not the
# same as harmless in aggregate when two drivers share one bus.
#
# Now that stage (b) covers the long tail, this only has to catch a hiccup that
# clears immediately, so it is shorter still - less time spent crowding the bus
# during the busiest part of boot.
IDENTIFY_RETRY_MS = 2000

# Stage (b): the deferred retry, which is what actually rescues a wedged boot.
#
# The gap is the whole design. One transfer every 5s is roughly a twentieth of
# the bus traffic the old synchronous loop generated, so the panel controller
# gets its writes through while this is still waiting - the two failures stop
# competing. The deadline covers the ~100s wedge measured on this hardware,
# with margin, and matches the recovery service's own budget.
# With no touch IRQ wired on this carrier the driver polls, and on a wedged
# boot every poll is a failed transfer competing with the panel controller for
# the bus. Slow down after a few consecutive failures; a working touchscreen
# never reaches the threshold, and one good read restores 60 Hz immediately.
POLL_BACKOFF_MS = 500
POLL_BACKOFF_AFTER = 4

IDENTIFY_DEFER_MS = 5000
IDENTIFY_DEADLINE_MS = 150000

POLL_FNS = """static void edt_ft5x06_ts_irq_poll_timer(struct timer_list *t)
{
\tstruct edt_ft5x06_ts_data *tsdata = timer_container_of(tsdata, t, timer);

\tunsigned int interval = POLL_INTERVAL_MS;

\t/*
\t * Back off while the bus is refusing us. Polling a wedged bus at 60 Hz
\t * achieves nothing except crowding out the panel controller, which is
\t * trying to get the backlight on over the same wires.
\t */
\tif (tsdata->poll_errors > POLL_BACKOFF_AFTER)
\t\tinterval = POLL_BACKOFF_MS;

\tschedule_work(&tsdata->work_i2c_poll);
\tmod_timer(&tsdata->timer, jiffies + msecs_to_jiffies(interval));
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


# The C inserted by split_probe(). Kept as plain literals rather than built up
# inline: this driver's probe is the most intricate patch here, and a stray
# escape in a generated string is invisible until a board fails to bind.
BRINGUP_HEAD = '/*\n * The half of bring-up that needs the I2C bus. Split out of probe so that it\n * can be retried: on this hardware the bus can be unusable for the first\n * minute or so of a boot, and one attempt at probe time is not enough.\n */\nstatic int edt_ft5x06_ts_bringup(struct i2c_client *client)\n{\n\tstruct edt_ft5x06_ts_data *tsdata = i2c_get_clientdata(client);\n\tstruct input_dev *input = tsdata->input;\n\tunsigned long irq_flags;\n\tunsigned int val;\n\tu32 report_rate;\n\tint error;\n\n'

GUARD_OLD = '\terror = edt_ft5x06_ts_identify(client, tsdata);\n\tif (error) {\n\t\tdev_err(&client->dev, "touchscreen probe failed\\n");\n\t\treturn error;\n\t}\n'

GUARD_NEW = '\tif (!tsdata->identified) {\n\t\tunsigned long deadline =\n\t\t\tjiffies + msecs_to_jiffies(EDT_IDENTIFY_RETRY_MS);\n\n\t\t/*\n\t\t * A short synchronous window first, so an ordinary transient\n\t\t * hiccup costs milliseconds instead of a whole deferral. Kept\n\t\t * short on purpose: every attempt here is bus traffic the panel\n\t\t * controller cannot use, and stretching this window to 40 s once\n\t\t * made both failures worse - touch went from 1-in-4 missing to\n\t\t * 3-in-6, and the backlight re-assert slipped from 11.7 s to 54 s.\n\t\t *\n\t\t * Reset is deliberately NOT pulsed between attempts. On this\n\t\t * board that line is a GPIO on the panel controller, driven over\n\t\t * this same bus, so each pulse is two writes to REG_PORTC - and\n\t\t * PORTC writes fail most of the time and wedge the bus outright\n\t\t * after a handful. It was already pulsed once before this.\n\t\t */\n\t\tfor (;;) {\n\t\t\terror = edt_ft5x06_ts_identify(client, tsdata);\n\t\t\tif (!error)\n\t\t\t\tbreak;\n\t\t\tif (time_after(jiffies, deadline))\n\t\t\t\treturn error;\n\t\t\tmsleep(250);\n\t\t}\n\t\ttsdata->identified = true;\n\t}\n\n'

BRINGUP_REST = '\n/*\n * Is this failure the bus being unavailable, rather than the device being\n * absent or broken? Only the first is worth waiting out.\n */\nstatic bool edt_ft5x06_bus_busy(int error)\n{\n\treturn error == -ETIMEDOUT || error == -EIO ||\n\t       error == -EREMOTEIO || error == -EAGAIN ||\n\t       error == -ENXIO || error == -EBUSY;\n}\n\nstatic void edt_ft5x06_ts_identify_work(struct work_struct *work)\n{\n\tstruct edt_ft5x06_ts_data *tsdata = container_of(work,\n\t\t\tstruct edt_ft5x06_ts_data, identify_work.work);\n\tstruct i2c_client *client = tsdata->client;\n\tint error;\n\n\terror = edt_ft5x06_ts_bringup(client);\n\tif (!error) {\n\t\tdev_info(&client->dev,\n\t\t\t "touchscreen came up %u ms into the retry window\\n",\n\t\t\t EDT_IDENTIFY_DEADLINE_MS -\n\t\t\t jiffies_to_msecs(tsdata->identify_deadline - jiffies));\n\t\treturn;\n\t}\n\n\t/*\n\t * Past identify, a failure is a real fault rather than a busy bus, and\n\t * retrying would re-register resources that already exist.\n\t */\n\tif (tsdata->identified || !edt_ft5x06_bus_busy(error)) {\n\t\tdev_err(&client->dev,\n\t\t\t"touchscreen bring-up failed: %d\\n", error);\n\t\treturn;\n\t}\n\n\tif (time_after(jiffies, tsdata->identify_deadline)) {\n\t\tdev_err(&client->dev,\n\t\t\t"touchscreen never answered: %d. The I2C bus stayed busy for longer than %d ms.\\n",\n\t\t\terror, EDT_IDENTIFY_DEADLINE_MS);\n\t\treturn;\n\t}\n\n\t/*\n\t * Nothing is held between attempts - no bus, no mutex, no lock. That is\n\t * the whole point. The panel controller shares this bus and needs it to\n\t * turn the backlight on; spinning here is what used to make a dark\n\t * panel and a missing touchscreen the same bug.\n\t */\n\tschedule_delayed_work(&tsdata->identify_work,\n\t\t\t      msecs_to_jiffies(EDT_IDENTIFY_DEFER_MS));\n}\n\nstatic void edt_ft5x06_cancel_identify(void *data)\n{\n\tstruct edt_ft5x06_ts_data *tsdata = data;\n\n\tcancel_delayed_work_sync(&tsdata->identify_work);\n}\n\n'

PROBE_TAIL = '\terror = edt_ft5x06_ts_bringup(client);\n\tif (!error)\n\t\treturn 0;\n\n\tif (tsdata->identified || !edt_ft5x06_bus_busy(error)) {\n\t\tdev_err(&client->dev, "touchscreen probe failed: %d\\n", error);\n\t\treturn error;\n\t}\n\n\t/*\n\t * The bus is busy, not the device missing. Failing here would lose the\n\t * touchscreen for the whole session over a condition that clears by\n\t * itself - measured at about 100 s on this hardware. Stay bound and\n\t * keep asking, quietly, from a work item.\n\t */\n\ttsdata->identify_deadline =\n\t\tjiffies + msecs_to_jiffies(EDT_IDENTIFY_DEADLINE_MS);\n\tINIT_DELAYED_WORK(&tsdata->identify_work, edt_ft5x06_ts_identify_work);\n\n\terror = devm_add_action_or_reset(&client->dev,\n\t\t\t\t\t edt_ft5x06_cancel_identify, tsdata);\n\tif (error)\n\t\treturn error;\n\n\tdev_info(&client->dev,\n\t\t "I2C bus busy, finishing touchscreen setup in the background\\n");\n\tschedule_delayed_work(&tsdata->identify_work,\n\t\t\t      msecs_to_jiffies(EDT_IDENTIFY_DEFER_MS));\n\treturn 0;\n}\n'


def split_probe(s):
    """Move probe's tail into edt_ft5x06_ts_bringup(), retried off a work item.

    The split point is edt_ft5x06_ts_identify(), because that is the first I2C
    traffic and everything before it is allocation that must happen exactly
    once. Retrying from there is therefore safe: on a wedged bus identify()
    fails before anything in the tail has run, so a later attempt starts from
    the same clean state instead of re-registering resources.
    """
    start = "\terror = edt_ft5x06_ts_identify(client, tsdata);"
    end = "\treturn 0;\n}\n"

    probe_at = s.rindex("static int edt_ft5x06_ts_probe(struct i2c_client *client)")

    i = s.index(start, probe_at)
    j = s.index(end, i) + len(end)
    tail = s[i:j]

    # Guard identify with the flag, so a retry that already got past it does
    # not repeat it, and so the caller can tell an identify failure - worth
    # waiting out - from a later one, which is a real fault.
    guarded = tail.replace(GUARD_OLD, GUARD_NEW, 1)
    if guarded == tail:
        raise SystemExit("split_probe: identify block not found in probe tail")

    # These locals live in the tail now. Left behind in probe they are unused,
    # and the kernel builds with -Werror: a warning here is a build failure for
    # everyone, on a driver most people never look at.
    brace = s.index("\n{", probe_at)
    first_stmt = s.index('dev_dbg(&client->dev, "probing for EDT FT5x06', probe_at)
    head = s[brace:first_stmt]
    for decl in ("\tunsigned int val;\n", "\tunsigned long irq_flags;\n",
                 "\tu32 report_rate;\n"):
        if decl not in head:
            raise SystemExit("split_probe: probe is missing %r" % decl)
        head = head.replace(decl, "", 1)
    s = s[:brace] + head + s[first_stmt:]

    # Everything shifted; locate probe and its tail again in the new text.
    probe_at = s.rindex("static int edt_ft5x06_ts_probe(struct i2c_client *client)")
    s = s[:probe_at] + BRINGUP_HEAD + guarded + BRINGUP_REST + s[probe_at:]

    probe_at = s.rindex("static int edt_ft5x06_ts_probe(struct i2c_client *client)")
    i = s.index(start, probe_at)
    j = s.index(end, i) + len(end)
    return s[:i] + PROBE_TAIL + s[j:]


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
            f"#define POLL_BACKOFF_MS\t\t\t{POLL_BACKOFF_MS}\n"
            f"#define POLL_BACKOFF_AFTER\t\t{POLL_BACKOFF_AFTER}\n"
            f"#define EDT_IDENTIFY_RETRY_MS\t\t{IDENTIFY_RETRY_MS}\n"
            f"#define EDT_IDENTIFY_DEFER_MS\t\t{IDENTIFY_DEFER_MS}\n"
            f"#define EDT_IDENTIFY_DEADLINE_MS\t{IDENTIFY_DEADLINE_MS}\n\n"
            "#define EDT_SWITCH_MODE_RETRIES", "poll defines")

    # 2. state for polling and release tracking
    s = sub(s, "\tunsigned int crc_errors;\n\tunsigned int header_errors;\n",
            "\tunsigned int crc_errors;\n\tunsigned int header_errors;\n\n"
            "\tunsigned int known_ids;\n\tint init_td_status;\n"
            "\tunsigned int poll_errors;\n"
            "\tstruct timer_list timer;\n\tstruct work_struct work_i2c_poll;\n"
            "\tstruct delayed_work identify_work;\n"
            "\tunsigned long identify_deadline;\n"
            "\tbool identified;\n",
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

    # 5b. count consecutive poll failures, so the timer can back off
    s = sub(s, '\tif (error) {\n\t\tdev_err_ratelimited(dev, "Unable to fetch data, error: %d\\n",\n\t\t\t\t    error);\n\t\tgoto out;\n\t}\n', '\tif (error) {\n\t\t/* Consecutive failures slow the poll timer down. */\n\t\ttsdata->poll_errors++;\n\t\tdev_err_ratelimited(dev, "Unable to fetch data, error: %d\\n",\n\t\t\t\t    error);\n\t\tgoto out;\n\t}\n\ttsdata->poll_errors = 0;\n', "poll error counter")

    # 6. probe: hand the bus-touching half of bring-up to a retryable function
    #
    # Everything from identify() onward needs the I2C bus, and on a wedged boot
    # none of it can succeed. Rather than fail the probe - which loses the
    # touchscreen for the whole session - that tail moves into
    # edt_ft5x06_ts_bringup(), which can simply be called again later.
    s = split_probe(s)

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

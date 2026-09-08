#!/usr/bin/env python3
"""Split the Goodix touch driver's reads so the Qualcomm CCI can carry them.

THE PROBLEM
-----------
The CCI I2C controller on this SoC is camera-oriented and refuses any read
longer than 12 bytes:

    read 12 bytes: OK
    read 13 bytes: FAIL   Operation not supported
    read 16 bytes: FAIL
    read 32 bytes: FAIL

goodix.c reads touch reports in one transfer - 32 bytes for a full contact
set - and its configuration table in another of 186. Both come back -EOPNOTSUPP
and the touchscreen produces no events at all:

    Goodix-TS 0-005d: Error reading 32 bytes from 0x8158: -95
    Goodix-TS 0-005d: Error reading 186 bytes from 0x8047: -95

This is the same limitation that edt-ft5x06 needs patching for on the other
panel family - see tools/patch-edt-ft5x06.py, which splits a 33 to 63 byte
read for exactly the same reason. Same controller, same ceiling, different
touch chip.

THE FIX
-------
Every read in this driver goes through one helper, so the whole problem has a
single chokepoint. Loop it, reading at most 12 bytes per transfer and stepping
the register address as it goes. Goodix registers auto-increment, so a long
read and a series of short reads from successive addresses return the same
bytes - which is not an assumption here: tools/goodix-config.sh dumps the whole
192-byte config table in 8-byte pieces and gets a coherent, checksum-consistent
result.

Errors still report the chunk that actually failed rather than the length the
caller asked for, because a message saying "12 bytes" when the caller wanted 32
would send the next person hunting for a bug that is not there.

Usage: patch-goodix.py <goodix.c>
"""
import io
import sys

# Measured on an UNO Q + Media Carrier, kernel 7.0.0: 12 succeeds, 13 does not.
# Not a guess and not copied from a datasheet - probed one byte at a time.
MAX_READ = 12

OLD = """int goodix_i2c_read(struct i2c_client *client, u16 reg, u8 *buf, int len)
{
	struct i2c_msg msgs[2];
	__be16 wbuf = cpu_to_be16(reg);
	int ret;

	msgs[0].flags = 0;
	msgs[0].addr  = client->addr;
	msgs[0].len   = 2;
	msgs[0].buf   = (u8 *)&wbuf;

	msgs[1].flags = I2C_M_RD;
	msgs[1].addr  = client->addr;
	msgs[1].len   = len;
	msgs[1].buf   = buf;

	ret = i2c_transfer(client->adapter, msgs, 2);
	if (ret >= 0)
		ret = (ret == ARRAY_SIZE(msgs) ? 0 : -EIO);

	if (ret)
		dev_err(&client->dev, "Error reading %d bytes from 0x%04x: %d\\n",
			len, reg, ret);
	return ret;
}"""

NEW = """int goodix_i2c_read(struct i2c_client *client, u16 reg, u8 *buf, int len)
{
	struct i2c_msg msgs[2];
	__be16 wbuf;
	int done = 0;
	int ret;

	/*
	 * Split into pieces the bus can actually carry. Qualcomm's CCI
	 * controller is camera-oriented and refuses reads over
	 * GOODIX_MAX_READ_LEN bytes with -EOPNOTSUPP, so the 32-byte contact
	 * report and the 186-byte config table both fail outright and the
	 * touchscreen produces nothing. Goodix registers auto-increment, so
	 * successive short reads return what one long read would have.
	 */
	while (done < len) {
		int chunk = min(len - done, GOODIX_MAX_READ_LEN);

		wbuf = cpu_to_be16(reg + done);

		msgs[0].flags = 0;
		msgs[0].addr  = client->addr;
		msgs[0].len   = 2;
		msgs[0].buf   = (u8 *)&wbuf;

		msgs[1].flags = I2C_M_RD;
		msgs[1].addr  = client->addr;
		msgs[1].len   = chunk;
		msgs[1].buf   = buf + done;

		ret = i2c_transfer(client->adapter, msgs, 2);
		if (ret >= 0)
			ret = (ret == ARRAY_SIZE(msgs) ? 0 : -EIO);

		if (ret) {
			/*
			 * Report the transfer that failed, not the length the
			 * caller wanted - otherwise the message describes a
			 * read this driver never attempted.
			 */
			dev_err(&client->dev,
				"Error reading %d bytes from 0x%04x: %d\\n",
				chunk, reg + done, ret);
			return ret;
		}

		done += chunk;
	}

	return 0;
}"""


def main():
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    path = sys.argv[1]

    with io.open(path, encoding="utf-8", newline="") as fh:
        text = fh.read()

    if "GOODIX_MAX_READ_LEN" in text:
        print("  goodix already patched")
        return

    if OLD not in text:
        sys.exit("goodix_i2c_read does not match - has the driver changed?")

    text = text.replace(OLD, NEW, 1)

    # Put the limit next to the driver's other tunables, above the helper.
    anchor = "/**\n * goodix_i2c_read - read data from a register"
    if anchor not in text:
        sys.exit("could not find a place for the define")
    text = text.replace(
        anchor,
        "/* The largest read Qualcomm's CCI controller will carry. Measured. */\n"
        "#define GOODIX_MAX_READ_LEN\t%d\n\n" % MAX_READ + anchor, 1)

    text = "/* patched by uno-q-dsi-panel: CCI-sized reads */\n" + text

    with io.open(path, "w", encoding="utf-8", newline="\n") as fh:
        fh.write(text)

    print("  goodix: reads split into %d-byte transfers for CCI" % MAX_READ)


if __name__ == "__main__":
    main()

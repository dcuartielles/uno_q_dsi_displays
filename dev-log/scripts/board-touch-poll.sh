#!/bin/sh
# Runs ON the UNO Q. Stdin secrets contract: 1. sudo password  2. SSID  3. wifi pw
#
# Userspace touch readout for the FT5x06 at 0x38, bypassing the kernel driver
# (mainline edt-ft5x06 needs an IRQ we do not have; RPi's version polls).
#
# Doubles as a diagnostic: while polling touch it probes the ATTINY at 0x45 once
# a second. Whether the two chips fail TOGETHER or INDEPENDENTLY distinguishes a
# panel-wide supply problem from an ATTINY-specific one.
#
# NB: the python must be written to a FILE, not fed on stdin - the sudo helper
# uses stdin to pass the password.
unset HISTFILE
IFS= read -r SUDO_PASS; SUDO_PASS=$(printf '%s' "$SUDO_PASS" | tr -d '\r')
IFS= read -r WIFI_SSID
IFS= read -r WIFI_PASS
S() { printf '%s\n' "$SUDO_PASS" | sudo -S -p '' "$@"; }
S true 2>/dev/null || { echo "SUDO PASSWORD REJECTED"; exit 1; }

B=$(basename "$(ls -d /sys/bus/i2c/devices/*-0045 2>/dev/null | head -1)" | cut -d- -f1)

cat > /tmp/touchpoll.py <<'PY'
import fcntl, os, sys, time

I2C_SLAVE_FORCE = 0x0706
bus = int(sys.argv[1])
dur = float(sys.argv[2]) if len(sys.argv) > 2 else 30.0
fd = os.open('/dev/i2c-%d' % bus, os.O_RDWR)

def rd(addr, reg, n):
    fcntl.ioctl(fd, I2C_SLAVE_FORCE, addr)
    os.write(fd, bytes([reg]))
    return os.read(fd, n)

def rd_attiny(reg):
    # the ATTINY wants the address write and the read as separate transactions
    fcntl.ioctl(fd, I2C_SLAVE_FORCE, 0x45)
    os.write(fd, bytes([reg]))
    time.sleep(0.006)
    return os.read(fd, 1)[0]

t0 = time.time()
t_end = t0 + dur
last_probe = 0.0
touches_seen = 0
touch_ok = touch_fail = 0
att_ok = att_fail = 0
last_report = ''

while time.time() < t_end:
    try:
        d = rd(0x38, 0x00, 32)
        touch_ok += 1
        td = d[0x02] & 0x0f
        if td:
            pts = []
            for i in range(min(td, 5)):
                o = 0x03 + i * 6
                xh, xl, yh, yl = d[o], d[o+1], d[o+2], d[o+3]
                ev  = xh >> 6
                x   = ((xh & 0x0f) << 8) | xl
                tid = yh >> 4
                y   = ((yh & 0x0f) << 8) | yl
                pts.append("id%d(%d,%d)ev%d" % (tid, x, y, ev))
            line = "TOUCH n=%d  %s" % (td, "  ".join(pts))
            if line != last_report:
                print("  " + line, flush=True)
                last_report = line
            touches_seen += 1
    except Exception:
        touch_fail += 1

    if time.time() - last_probe >= 1.0:
        last_probe = time.time()
        try:
            v = rd_attiny(0x80)
            att_ok += 1
            state = "ok(0x%02x)" % v
        except Exception:
            att_fail += 1
            state = "FAIL"
        print("    [%5.1fs] attiny=%-10s touch_reads ok=%d fail=%d"
              % (time.time() - t0, state, touch_ok, touch_fail), flush=True)

    time.sleep(0.02)

os.close(fd)
print()
print("=== summary over %.0fs ===" % dur)
print("  touch chip @0x38 : %d reads ok, %d failed" % (touch_ok, touch_fail))
print("  attiny     @0x45 : %d probes ok, %d failed" % (att_ok, att_fail))
print("  samples with a finger down: %d" % touches_seen)
print()
if touches_seen:
    print("  >>> TOUCH IS WORKING - the digitiser is alive and reporting coordinates")
else:
    print("  >>> no touches seen (none applied, or the digitiser is not reporting)")
PY

echo "i2c bus = $B"
echo
echo "=== touch chip identity ==="
for r in A3 A6 A8; do
    printf '  0x%s = %s\n' "$r" "$(S i2cget -f -y "$B" 0x38 0x$r 2>&1)"
done

echo
echo "*** TOUCH AND DRAG ON THE PANEL FOR THE NEXT 30 SECONDS ***"
echo "    (the panel being dark does not matter - the digitiser is separate)"
echo
S python3 /tmp/touchpoll.py "$B" 30

#!/bin/sh
# Runs ON the UNO Q. Stdin secrets contract: 1. sudo password  2. SSID  3. wifi pw
#
# v2 of the userspace touch readout. The 32-byte burst read failed on every
# attempt while single-register i2cget reads worked, so this uses SMBus-style
# single-byte reads (the same access the working i2cget used) and reports the
# actual exception if anything still fails.
unset HISTFILE
IFS= read -r SUDO_PASS; SUDO_PASS=$(printf '%s' "$SUDO_PASS" | tr -d '\r')
IFS= read -r WIFI_SSID
IFS= read -r WIFI_PASS
S() { printf '%s\n' "$SUDO_PASS" | sudo -S -p '' "$@"; }
S true 2>/dev/null || { echo "SUDO PASSWORD REJECTED"; exit 1; }

B=$(basename "$(ls -d /sys/bus/i2c/devices/*-0045 2>/dev/null | head -1)" | cut -d- -f1)

cat > /tmp/touchpoll2.py <<'PY'
import fcntl, os, sys, time, ctypes

I2C_SLAVE_FORCE = 0x0706
I2C_SMBUS       = 0x0720
I2C_SMBUS_READ  = 1
I2C_SMBUS_BYTE_DATA = 2

class SmbusData(ctypes.Union):
    _fields_ = [("byte", ctypes.c_ubyte),
                ("word", ctypes.c_ushort),
                ("block", ctypes.c_ubyte * 34)]

class SmbusIoctl(ctypes.Structure):
    _fields_ = [("read_write", ctypes.c_ubyte),
                ("command", ctypes.c_ubyte),
                ("size", ctypes.c_uint),
                ("data", ctypes.POINTER(SmbusData))]

bus = int(sys.argv[1])
dur = float(sys.argv[2]) if len(sys.argv) > 2 else 30.0
fd = os.open('/dev/i2c-%d' % bus, os.O_RDWR)
cur_addr = [None]

def set_addr(addr):
    if cur_addr[0] != addr:
        fcntl.ioctl(fd, I2C_SLAVE_FORCE, addr)
        cur_addr[0] = addr

def smbus_read_byte(addr, reg):
    """exactly what i2cget does by default - this is known to work here"""
    set_addr(addr)
    data = SmbusData()
    arg = SmbusIoctl(I2C_SMBUS_READ, reg, I2C_SMBUS_BYTE_DATA, ctypes.pointer(data))
    fcntl.ioctl(fd, I2C_SMBUS, arg)
    return data.byte

def rd_attiny(reg):
    set_addr(0x45)
    os.write(fd, bytes([reg]))
    time.sleep(0.006)
    return os.read(fd, 1)[0]

# prove the access method works before looping
try:
    print("  probe: touch 0xA3 = 0x%02x  0xA8 = 0x%02x"
          % (smbus_read_byte(0x38, 0xA3), smbus_read_byte(0x38, 0xA8)), flush=True)
except Exception as e:
    print("  probe FAILED: %r" % (e,), flush=True)

t0 = time.time(); t_end = t0 + dur
last_probe = 0.0
touch_ok = touch_fail = 0
att_ok = att_fail = 0
touches_seen = 0
last_line = ''
first_err = None

while time.time() < t_end:
    try:
        td = smbus_read_byte(0x38, 0x02) & 0x0f
        touch_ok += 1
        if td:
            pts = []
            for i in range(min(td, 5)):
                o = 0x03 + i * 6
                xh = smbus_read_byte(0x38, o)
                xl = smbus_read_byte(0x38, o + 1)
                yh = smbus_read_byte(0x38, o + 2)
                yl = smbus_read_byte(0x38, o + 3)
                ev  = xh >> 6
                x   = ((xh & 0x0f) << 8) | xl
                tid = yh >> 4
                y   = ((yh & 0x0f) << 8) | yl
                pts.append("id%d(%4d,%4d)ev%d" % (tid, x, y, ev))
            line = "TOUCH n=%d  %s" % (td, "  ".join(pts))
            if line != last_line:
                print("  " + line, flush=True)
                last_line = line
            touches_seen += 1
    except Exception as e:
        touch_fail += 1
        if first_err is None:
            first_err = repr(e)

    if time.time() - last_probe >= 1.0:
        last_probe = time.time()
        try:
            v = rd_attiny(0x80); att_ok += 1; st = "ok(0x%02x)" % v
        except Exception:
            att_fail += 1; st = "FAIL"
        print("    [%5.1fs] attiny=%-11s touch ok=%d fail=%d"
              % (time.time() - t0, st, touch_ok, touch_fail), flush=True)
    time.sleep(0.02)

os.close(fd)
print()
print("=== summary over %.0fs ===" % dur)
print("  touch @0x38 : %d reads ok, %d failed" % (touch_ok, touch_fail))
print("  attiny@0x45 : %d probes ok, %d failed" % (att_ok, att_fail))
print("  samples with a finger down: %d" % touches_seen)
if first_err:
    print("  first touch error: %s" % first_err)
print()
if touches_seen:
    print("  >>> TOUCH WORKS - the digitiser reports coordinates")
elif touch_ok:
    print("  >>> digitiser READABLE but reported no contacts")
else:
    print("  >>> digitiser not readable")
PY

echo "i2c bus = $B"
echo
echo "*** TOUCH AND DRAG ON THE PANEL FOR 30 SECONDS (dark panel is fine) ***"
echo
S python3 /tmp/touchpoll2.py "$B" 30

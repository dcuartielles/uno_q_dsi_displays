#!/bin/sh
# Runs ON the UNO Q. Stdin secrets contract: 1. sudo password  2. SSID  3. wifi pw
#
# v3: read the FT5x06 with a proper I2C_RDWR combined transaction (write reg
# pointer + repeated START + read block) - the same access the kernel's regmap
# uses. v1 used write-then-read as two transactions; v2 used per-register SMBus
# reads; both failed on the data registers with ENXIO.
unset HISTFILE
IFS= read -r SUDO_PASS; SUDO_PASS=$(printf '%s' "$SUDO_PASS" | tr -d '\r')
IFS= read -r WIFI_SSID
IFS= read -r WIFI_PASS
S() { printf '%s\n' "$SUDO_PASS" | sudo -S -p '' "$@"; }
S true 2>/dev/null || { echo "SUDO PASSWORD REJECTED"; exit 1; }

B=$(basename "$(ls -d /sys/bus/i2c/devices/*-0045 2>/dev/null | head -1)" | cut -d- -f1)

cat > /tmp/touchpoll3.py <<'PY'
import fcntl, os, sys, time, ctypes

I2C_RDWR        = 0x0707
I2C_SLAVE_FORCE = 0x0706
I2C_M_RD        = 0x0001

class i2c_msg(ctypes.Structure):
    _fields_ = [("addr", ctypes.c_uint16), ("flags", ctypes.c_uint16),
                ("len", ctypes.c_uint16), ("buf", ctypes.POINTER(ctypes.c_ubyte))]

class i2c_rdwr_ioctl_data(ctypes.Structure):
    _fields_ = [("msgs", ctypes.POINTER(i2c_msg)), ("nmsgs", ctypes.c_uint32)]

bus = int(sys.argv[1])
dur = float(sys.argv[2]) if len(sys.argv) > 2 else 30.0
fd  = os.open('/dev/i2c-%d' % bus, os.O_RDWR)

def block_read(addr, reg, n):
    """write reg pointer, repeated START, read n bytes - ONE transaction"""
    wbuf = (ctypes.c_ubyte * 1)(reg)
    rbuf = (ctypes.c_ubyte * n)()
    msgs = (i2c_msg * 2)(
        i2c_msg(addr, 0,        1, wbuf),
        i2c_msg(addr, I2C_M_RD, n, rbuf))
    data = i2c_rdwr_ioctl_data(msgs, 2)
    fcntl.ioctl(fd, I2C_RDWR, data)
    return bytes(rbuf)

def rd_attiny(reg):
    fcntl.ioctl(fd, I2C_SLAVE_FORCE, 0x45)
    os.write(fd, bytes([reg])); time.sleep(0.006)
    return os.read(fd, 1)[0]

try:
    d = block_read(0x38, 0x00, 16)
    print("  block read OK: " + " ".join("%02x" % b for b in d), flush=True)
except Exception as e:
    print("  block read FAILED: %r" % (e,), flush=True)

t0 = time.time(); t_end = t0 + dur
last = 0.0; ok = bad = 0; att_ok = att_bad = 0; seen = 0; lastline = ''; firsterr = None
maxtd = 0

while time.time() < t_end:
    try:
        d = block_read(0x38, 0x00, 32)
        ok += 1
        td = d[0x02] & 0x0f
        maxtd = max(maxtd, td)
        if 0 < td <= 5:
            pts = []
            for i in range(td):
                o = 0x03 + i * 6
                xh, xl, yh, yl = d[o], d[o+1], d[o+2], d[o+3]
                ev  = xh >> 6
                x   = ((xh & 0x0f) << 8) | xl
                tid = yh >> 4
                y   = ((yh & 0x0f) << 8) | yl
                if ev != 1:                      # 1 = lift-off
                    pts.append("id%d(%4d,%4d)" % (tid, x, y))
            if pts:
                line = "TOUCH n=%d  %s" % (td, "  ".join(pts))
                if line != lastline:
                    print("  " + line, flush=True); lastline = line
                seen += 1
    except Exception as e:
        bad += 1
        if firsterr is None: firsterr = repr(e)

    if time.time() - last >= 1.0:
        last = time.time()
        try:
            v = rd_attiny(0x80); att_ok += 1; st = "ok(0x%02x)" % v
        except Exception:
            att_bad += 1; st = "FAIL"
        print("    [%5.1fs] attiny=%-11s touch ok=%d fail=%d maxTD=%d"
              % (time.time() - t0, st, ok, bad, maxtd), flush=True)
    time.sleep(0.02)

os.close(fd)
print()
print("=== summary over %.0fs ===" % dur)
print("  touch @0x38 : %d block reads ok, %d failed   (max TD_STATUS seen: %d)" % (ok, bad, maxtd))
print("  attiny@0x45 : %d probes ok, %d failed" % (att_ok, att_bad))
print("  samples with a contact: %d" % seen)
if firsterr: print("  first error: %s" % firsterr)
print()
print("  >>> TOUCH WORKS" if seen else "  >>> no contacts reported")
PY

echo "i2c bus = $B"
echo
echo "*** TOUCH AND DRAG ON THE PANEL FOR 30 SECONDS ***"
echo
S python3 /tmp/touchpoll3.py "$B" 30

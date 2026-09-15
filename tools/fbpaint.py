#!/usr/bin/env python3
"""Shared playback for the moving test patterns.

Imported by spiral.py and tunnel.py, which differ only in what they draw. Both
render their animation up front as a ring of complete frames and then hand it
here, because stamping pixels per frame in Python on this SoC does not reach a
frame rate worth watching; playing back a pre-rendered ring is one buffer write
per frame and does.

The parts worth having in one place rather than two:

  - what counts as a touchscreen, matched on capability rather than driver name
  - holding the console against lightdm, which takes it back for its own
    reasons and stops the picture with nothing logged anywhere
  - waiting for the frame ON the touch descriptors, so a finger lands within a
    frame rather than within a poll interval
"""
import glob
import os
import re
import select
import sys
import time

# Returned by play(), and used as the process exit status by both callers.
DONE = 0
TOUCHED = 3


def packer(bpp):
    """Return (bytes_per_pixel, pack(r, g, b)) for this framebuffer."""
    if bpp == 32:
        return 4, lambda r, g, b: bytes((b, g, r, 0))
    if bpp == 24:
        return 3, lambda r, g, b: bytes((b, g, r))
    if bpp == 16:
        def pack(r, g, b):
            v = ((r >> 3) << 11) | ((g >> 2) << 5) | (b >> 3)
            return bytes((v & 0xFF, v >> 8))
        return 2, pack
    raise SystemExit("unsupported bits_per_pixel: %s" % bpp)


def touch_devices():
    """Every input device that reports a multitouch position.

    Matched on the capability rather than the driver name: this repository
    already drives two different controllers and more will turn up.
    """
    devs = []
    try:
        blocks = open("/proc/bus/input/devices").read().split("\n\n")
    except IOError:
        blocks = []
    for b in blocks:
        m = re.search(r"B: ABS=([0-9a-f]+)", b)
        if not m:
            continue
        # bit 0x35 is ABS_MT_POSITION_X - set by every multitouch panel here.
        if not (int(m.group(1), 16) >> 0x35) & 1:
            continue
        for h in re.findall(r"event\d+", b):
            devs.append("/dev/input/" + h)
    return devs or sorted(glob.glob("/dev/input/event*"))


def frame_budget(height, stride, wanted, share=0.35):
    """Trim a frame ring to something this board can actually hold.

    A ring at 1024x600x32 is 2.4 MB a frame. Asking for a long one on a board
    with other work running is a way to meet the OOM killer rather than a test
    pattern, so the ceiling comes from MemAvailable rather than from optimism.
    """
    try:
        avail = None
        for line in open("/proc/meminfo"):
            if line.startswith("MemAvailable:"):
                avail = int(line.split()[1]) * 1024
                break
        if avail is None:
            return wanted
    except IOError:
        return wanted
    allowed = max(8, int(avail * share / (stride * height)))
    if allowed < wanted:
        sys.stderr.write("  trimming ring to %d frames to fit memory\n"
                         % allowed)
        return allowed
    return wanted


def play(ring, fps=15.0, seconds=120.0, vt="", hold=False, until_touch=False):
    """Loop a ring of frames into /dev/fb0. Returns DONE or TOUCHED."""
    fds = {}
    if until_touch:
        for d in touch_devices():
            try:
                fds[os.open(d, os.O_RDONLY | os.O_NONBLOCK)] = d
            except OSError:
                pass
        if not fds:
            sys.stderr.write("  no touchscreen found - running on time only\n")

    try:
        fb = open("/dev/fb0", "r+b", buffering=0)
    except IOError as exc:
        raise SystemExit("cannot open /dev/fb0: %s" % exc)

    frames = len(ring)
    deadline = float("inf") if hold else time.time() + seconds
    period = 1.0 / fps
    steals = 0
    n = 0

    # A touch already pending before the pattern went up would dismiss it
    # instantly - the finger that dismissed the LAST one, or the tap that
    # started this over adb. Drain whatever is queued before arming.
    for fd in fds:
        try:
            while os.read(fd, 4096):
                pass
        except OSError:
            pass

    while time.time() < deadline:
        fb.seek(0)
        fb.write(ring[n % frames])
        n += 1

        if fds:
            r, _, _ = select.select(list(fds), [], [], period)
            for fd in r:
                try:
                    if os.read(fd, 4096):
                        return TOUCHED
                except OSError:
                    pass
        else:
            time.sleep(period)

        # lightdm takes the console back for its own reasons, and when it does
        # the picture stops with nothing logged anywhere. Checked once a second
        # rather than every frame - it is a sysfs read, not free.
        if vt and n % max(1, int(fps)) == 0:
            try:
                active = open("/sys/class/tty/tty0/active").read().strip()
            except IOError:
                active = vt
            if active != vt:
                steals += 1
                os.system("chvt %s" % vt[3:])
                time.sleep(0.4)
                sys.stderr.write("  console was taken back (%d) - resuming\n"
                                 % steals)

    return DONE

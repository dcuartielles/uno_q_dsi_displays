#!/usr/bin/env python3
"""Draw a rotating spiral straight into the framebuffer.

    spiral.py --width 720 --height 720 --stride 2944 --bpp 32 --seconds 60

Called by scripts/show-spiral.sh, which is what takes the console first - this
writes to /dev/fb0 and nothing else.

HOW THE MOTION IS DONE
----------------------
Not by redrawing every frame. A 720x720 panel at 32bpp is 2.1 MB a frame, and
stamping a few tens of thousands of pixels per frame in Python on this SoC does
not keep up with any frame rate worth watching.

Instead the whole animation is rendered ONCE, up front, as a small ring of
complete frames - one per rotation step - and then played back by seeking to
zero and writing a buffer. A full turn is a rotation of the spiral by 2*pi, so
the ring loops seamlessly and can be replayed for as long as it is wanted at
the cost of one memcpy per frame.

The ring costs stride * height * frames bytes, which is about 40 MB at 720x720
with the default settings. That is the trade being made: memory up front, and a
few seconds of rendering, in exchange for a frame rate that actually looks like
motion.

WHY A SPIRAL, AND WHY INSIDE THE INSCRIBED CIRCLE
-------------------------------------------------
The Waveshare 4.0inch DSI-TOUCH-C is a ROUND panel behind a square 720x720
framebuffer: the corners are not physically there. Anything drawn to the edges
of that square loses its extremities to the bezel, and a picture whose edges
are missing tells you nothing about whether the glass cut them off or the
timings did.

A spiral bounded by the inscribed circle is fully visible on a round panel and
on a square one, and it is rotationally symmetric - so shear, a wrong stride or
a wrong mode turn the circle into an oval or a staircase immediately, which a
grid of colour bars does not do nearly as clearly.
"""
import argparse
import math
import sys

import fbpaint

# Arduino teal at the centre running out to white at the rim. The bright edge
# is deliberate: on a round panel the rim is where the glass ends, so a picture
# that is brightest there makes the circle itself the thing you are checking.
CORE = (0, 129, 132)
RIM = (255, 255, 255)


def brushes(max_t, stride, bpp_bytes):
    """Filled discs of every radius up to max_t, as flat byte offsets.

    Precomputing the offsets means the inner loop adds rather than multiplies,
    which is most of what makes the render bearable in Python.
    """
    out = []
    for t in range(max_t + 1):
        offs = []
        for dy in range(-t, t + 1):
            for dx in range(-t, t + 1):
                if dx * dx + dy * dy <= t * t:
                    offs.append(dy * stride + dx * bpp_bytes)
        out.append(offs)
    return out


def spiral_points(radius, turns, step_len):
    """Samples along an Archimedean spiral, roughly step_len pixels apart.

    r = a*theta, so a step of fixed ARC length is a step of varying angle -
    d(theta) = ds / sqrt(r^2 + a^2). Stepping in theta directly would crowd the
    samples at the centre and leave gaps at the rim.
    """
    th_max = turns * 2.0 * math.pi
    a = radius / th_max
    pts = []
    th = 0.35
    while th < th_max:
        r = a * th
        pts.append((r, th))
        th += step_len / math.sqrt(r * r + a * a)
    return pts


def render(width, height, stride, bpp, frames, turns):
    bpp_bytes, pack = fbpaint.packer(bpp)

    thin, thick = 2, 4
    disc = brushes(thick, stride, bpp_bytes)

    # Bounded by the inscribed circle, less the brush, so nothing is clipped
    # and the inner loop needs no bounds test at all.
    radius = min(width, height) / 2.0 - (thick + 2)
    cx, cy = width / 2.0, height / 2.0

    pts = spiral_points(radius, turns, 1.6)

    # Colour and thickness vary along the curve, not around it, so both are
    # settled once per sample here and simply reused at every rotation.
    shaped = []
    for r, th in pts:
        f = r / radius
        col = pack(*(int(round(CORE[i] + (RIM[i] - CORE[i]) * (f ** 0.8)))
                     for i in range(3)))
        shaped.append((r, th, col, disc[int(round(thin + (thick - thin) * f))]))

    blank = bytearray(stride * height)
    ring = []
    for n in range(frames):
        phase = 2.0 * math.pi * n / frames
        buf = bytearray(blank)
        for r, th, col, offs in shaped:
            ang = th + phase
            base = (int(cy + r * math.sin(ang)) * stride
                    + int(cx + r * math.cos(ang)) * bpp_bytes)
            for o in offs:
                p = base + o
                buf[p:p + bpp_bytes] = col
        ring.append(bytes(buf))
        sys.stderr.write("\r  rendering %d/%d" % (n + 1, frames))
        sys.stderr.flush()
    sys.stderr.write("\r  rendered %d frames          \n" % frames)
    return ring


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--width", type=int, required=True)
    ap.add_argument("--height", type=int, required=True)
    ap.add_argument("--stride", type=int, required=True)
    ap.add_argument("--bpp", type=int, default=32)
    ap.add_argument("--seconds", type=float, default=120.0)
    ap.add_argument("--fps", type=float, default=12.0)
    ap.add_argument("--turns", type=float, default=4.0)
    ap.add_argument("--vt", default="")
    ap.add_argument("--hold", action="store_true")
    ap.add_argument("--until-touch", action="store_true")
    args = ap.parse_args()

    # One revolution every two seconds, whatever the frame rate - so --fps
    # buys smoothness rather than speed, and the ring stays a sane size.
    frames = max(8, min(36, int(round(args.fps * 2.0))))
    frames = fbpaint.frame_budget(args.height, args.stride, frames)
    ring = render(args.width, args.height, args.stride, args.bpp,
                  frames, args.turns)

    sys.exit(fbpaint.play(ring, fps=args.fps, seconds=args.seconds,
                          vt=args.vt, hold=args.hold,
                          until_touch=args.until_touch))


if __name__ == "__main__":
    main()

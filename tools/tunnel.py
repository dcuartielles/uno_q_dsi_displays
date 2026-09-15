#!/usr/bin/env python3
"""Drive into a tunnel of concentric rectangles, straight into the framebuffer.

    tunnel.py --width 1024 --height 600 --stride 4096 --bpp 32 --seconds 60

Called by scripts/show-tunnel.sh, which is what takes the console first - this
writes to /dev/fb0 and nothing else.

WHY RECTANGLES
--------------
scripts/show-spiral.sh was written for a round panel and is bounded by the
inscribed circle, which wastes most of a wide one. A rectangular tunnel fills
the panel to all four edges, so it exercises the corners - and on a landscape
panel that is exactly where a wrong mode or a wrong stride shows itself.

It keeps the two properties that made the spiral worth having. It MOVES, so it
proves the panel is still being refreshed rather than showing one frame that
was painted and then froze - those photograph identically. And its geometry is
known, so a wrong stride shears the straight edges into staircases.

HOW THE MOTION LOOPS
--------------------
The rectangles are spaced geometrically - each one is `ratio` times the size of
the one outside it - and every frame they all grow by a fraction of that step.
After a whole step, rectangle k has arrived exactly where rectangle k-1 used to
be, so the picture is identical to the one a step earlier. The animation
therefore closes on itself, which is what lets the whole thing be rendered once
as a ring of frames and then played back with one buffer write per frame. That
is the only way this reaches a watchable frame rate in Python on this SoC.

The sway and the colour cycle are fitted to the same ring: both complete a
whole number of cycles across it, so nothing jumps at the wrap.

WHY THE RECTANGLES CANNOT TOUCH
-------------------------------
The vanishing point moves side to side, but the nearest rectangle does not -
each rectangle's centre is displaced by `sway * (1 - scale)`, which is zero for
the outermost and greatest for the farthest. That is what makes it read as
driving through a curving tunnel rather than as the whole image sliding about.

It also means the gap between neighbours never closes. For the left edges:

    gap = (s_k - s_k+1) * (halfwidth + sway)

and the right edges give the same with `- sway`. Since scales strictly
decrease inward, both stay positive for any |sway| < halfwidth - so with a sway
amplitude that is a fraction of the screen, the rectangles provably never meet.
It is not tuning that keeps them apart.
"""
import argparse
import math
import sys

import fbpaint

# Red, green, yellow, blue, and back to red - as hues, in degrees.
#
# Held as hues rather than as RGB triples on purpose. Interpolating the same
# four colours in RGB sends yellow -> blue through (152,170,152), a washed out
# grey-green that reads on screen as a white rectangle sitting in the middle of
# a saturated cycle. Around the hue circle at full saturation there is no such
# dead spot: every step between two colours is itself a colour.
#
# The path taken is the shorter arc, so red -> green sweeps through orange,
# green -> yellow runs back the short way, yellow -> blue passes through green
# and cyan, and blue -> red comes home through magenta.
PALETTE_HUES = (0.0, 120.0, 60.0, 240.0)


def hsv_to_rgb(h, s, v):
    """Standard conversion. h in degrees, s and v in 0..1."""
    h = h % 360.0
    c = v * s
    x = c * (1.0 - abs((h / 60.0) % 2.0 - 1.0))
    m = v - c
    # Wrapped, not just indexed. For a hue a hair below zero Python's modulo
    # returns exactly 360.0 rather than 0.0, which lands on a seventh sector
    # that does not exist - an IndexError in the middle of a test pattern,
    # which is the last place anyone wants to debug one.
    i = int(h // 60.0) % 6
    rgb = ((c, x, 0.0), (x, c, 0.0), (0.0, c, x),
           (0.0, x, c), (x, 0.0, c), (c, 0.0, x))[i]
    return tuple(int(round((z + m) * 255)) for z in rgb)


def colour_at(u):
    """Fade around the palette. u is a position on the loop, 0..1."""
    n = len(PALETTE_HUES)
    x = (u % 1.0) * n
    i = int(x)
    f = x - i
    a, b = PALETTE_HUES[i % n], PALETTE_HUES[(i + 1) % n]
    # Shorter way round the circle, so a fade never doubles back through
    # every other hue to reach a neighbour. Yellow to blue is a dead heat at
    # 180 degrees either way, so that tie is settled forwards deliberately -
    # through green and cyan rather than back through red, which would show
    # red twice in a cycle that already starts there.
    d = (b - a + 540.0) % 360.0 - 180.0
    if d < -179.999:
        d = 180.0
    return hsv_to_rgb(a + d * f, 0.95, 1.0)


def render(width, height, stride, bpp, frames, depth_cycles, sway_cycles,
           ratio, sway_frac):
    bpp_bytes, pack = fbpaint.packer(bpp)

    # Enough rectangles that the innermost is under a pixel across, so the
    # tunnel runs all the way to the vanishing point rather than stopping at a
    # visible smallest box.
    over = 1.0 / ratio                      # largest rectangle leaves the screen
    half_w = width / 2.0 * over
    half_h = height / 2.0 * over
    n_rect = 2
    while half_w * (ratio ** n_rect) > 0.5 and n_rect < 64:
        n_rect += 1

    cy = height / 2.0
    sway_amp = width * sway_frac
    # Colours repeat every this many rectangles, so the cycle advances along
    # the tunnel instead of every rectangle being a different colour.
    colour_span = 6.0

    blank = bytearray(stride * height)
    ring = []

    for n in range(frames):
        # Depth phase runs 0..1 repeatedly; one full run shifts every
        # rectangle onto its neighbour's place, which is what makes the ring
        # close on itself.
        t = (n * depth_cycles / float(frames)) % 1.0
        sway = sway_amp * math.sin(2.0 * math.pi * n * sway_cycles / frames)

        buf = bytearray(blank)
        for k in range(n_rect):
            s = ratio ** (k + 1.0 - t)
            hw, hh = half_w * s, half_h * s
            if hw < 1.0 or hh < 1.0:
                continue

            # The vanishing point moves; the nearest rectangle does not.
            cx = width / 2.0 + sway * (1.0 - s)

            x0, x1 = int(cx - hw), int(cx + hw)
            y0, y1 = int(cy - hh), int(cy + hh)

            # Nearer rectangles are drawn heavier, which reads as perspective
            # and keeps the far ones from turning into mush.
            th = max(1, int(round(1.0 + 3.0 * s)))
            if x1 - x0 <= 2 * th or y1 - y0 <= 2 * th:
                th = 1

            col = pack(*colour_at((k + 1.0 - t) / colour_span))

            # Every edge is a horizontal run, including the vertical sides -
            # a run is one slice assignment, and doing this per pixel instead
            # is what makes a renderer like this too slow to watch.
            def run(y, xa, xb):
                if y < 0 or y >= height:
                    return
                xa = 0 if xa < 0 else xa
                xb = width if xb > width else xb
                if xb <= xa:
                    return
                o = y * stride + xa * bpp_bytes
                buf[o:o + (xb - xa) * bpp_bytes] = col * (xb - xa)

            for y in range(y0, min(y0 + th, y1)):
                run(y, x0, x1)
            for y in range(max(y1 - th, y0), y1):
                run(y, x0, x1)
            for y in range(max(y0 + th, 0), min(y1 - th, height)):
                run(y, x0, x0 + th)
                run(y, x1 - th, x1)

        ring.append(bytes(buf))
        sys.stderr.write("\r  rendering %d/%d" % (n + 1, frames))
        sys.stderr.flush()

    sys.stderr.write("\r  rendered %d frames, %d rectangles deep      \n"
                     % (frames, n_rect))
    return ring


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--width", type=int, required=True)
    ap.add_argument("--height", type=int, required=True)
    ap.add_argument("--stride", type=int, required=True)
    ap.add_argument("--bpp", type=int, default=32)
    ap.add_argument("--seconds", type=float, default=120.0)
    ap.add_argument("--fps", type=float, default=15.0)
    ap.add_argument("--frames", type=int, default=60)
    ap.add_argument("--ratio", type=float, default=0.72,
                    help="size of each rectangle relative to the one outside")
    ap.add_argument("--sway", type=float, default=0.13,
                    help="vanishing point travel, as a fraction of the width")
    ap.add_argument("--depth-cycles", type=int, default=3)
    ap.add_argument("--sway-cycles", type=int, default=1)
    ap.add_argument("--vt", default="")
    ap.add_argument("--hold", action="store_true")
    ap.add_argument("--until-touch", action="store_true")
    args = ap.parse_args()

    frames = fbpaint.frame_budget(args.height, args.stride, args.frames)
    ring = render(args.width, args.height, args.stride, args.bpp, frames,
                  args.depth_cycles, args.sway_cycles, args.ratio, args.sway)

    sys.exit(fbpaint.play(ring, fps=args.fps, seconds=args.seconds,
                          vt=args.vt, hold=args.hold,
                          until_touch=args.until_touch))


if __name__ == "__main__":
    main()

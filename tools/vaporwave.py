#!/usr/bin/env python3
"""A vaporwave landscape, straight into the framebuffer.

    vaporwave.py --width 480 --height 1920 --stride 1920 --bpp 32 --rotate 90

Called by scripts/show-vaporwave.sh, which takes the console first - this
writes to /dev/fb0 and nothing else.

WHAT IS DRAWN
-------------
A purple perspective grid across the bottom half, converging on a vanishing
point at the centre of the image. A small wireframe sun in bright orange, a
quarter of the width in from the right. The word ARDUINO spread across the
whole frame, each letter riding a travelling sine wave and cycling through a
rainbow. Wireframe spaceships crossing the sky at random intervals, trailing
wireframe spheres out of their bases.

LANDSCAPE ON A PANEL THAT IS NOT
--------------------------------
The Waveshare 8.8inch is a 480x1920 bar - the framebuffer is tall and narrow,
and a vaporwave horizon composed into it would be a letterbox on its side. So
the scene is composed in LOGICAL coordinates, 1920x480, and every primitive
maps to physical pixels on the way out.

The mapping is picked so it stays fast. A rectangle in logical space is still a
rectangle in physical space under a quarter turn, so every primitive here is
built on `rect`, and a rect is whole-row slice assignments whichever way round
the panel is. Note which way the cost runs: under the turn a rect costs one
slice per unit of its LOGICAL WIDTH, so tall thin shapes are cheap and wide
flat ones are dear. That is why the letters are emitted as vertical runs.

`--rotate 90` and `--rotate 270` differ by half a turn, so whichever way the
panel is physically mounted, one of them is the right way up.

THE THREE LAYERS, AND WHY THE RING HOLDS ONLY ONE
-------------------------------------------------
Motion here runs on two different clocks, and that decides what can be
pre-rendered.

The grid repeats: its rows are spaced geometrically, so after one depth step
every row has arrived where its neighbour was and the picture is identical.
That closes into a ring of whole frames which playback writes one at a time -
the only way this reaches a watchable frame rate in Python on this SoC. The
sun and the converging rays never move, so they are drawn once into a base
frame that every ring frame starts from.

Everything else runs on wall-clock time and cannot repeat inside a ring a few
seconds long. Ships appear at intervals of five to thirty seconds and take ten
to thirty to cross; baking that in would need a ring of minutes, which at
480x1920x32 is gigabytes. So ships are drawn per displayed frame by the
overlay.

The letters had to leave the ring too, for a different reason: some ships pass
IN FRONT of the word and some BEHIND it. A layer baked into the ring can only
ever be behind, so the word is drawn per frame as well, between the two groups
of ships:

    ring frame   (grid, rays, sun)
    ships marked "behind"
    ARDUINO
    ships marked "in front"

Drawing the word per frame costs about three thousand slice assignments, which
is affordable only because each letter is emitted as vertical RUNS of cells
rather than cell by cell - see FONT_RUNS.
"""
import argparse
import math
import random
import sys
import time

import fbpaint

PURPLE = (170, 60, 255)
ORANGE = (255, 130, 20)
HORIZON = (120, 40, 190)

WORD = "ARDUINO"

# Ships come at intervals in this range and take this long to cross. Both ends
# matter: the short interval with the long crossing is what puts several in the
# sky at once, which is the case the frame budget has to survive.
SHIP_EVERY = (5.0, 30.0)
SHIP_CROSS = (10.0, 30.0)

# Each ship is between half and full size. "Full" is the size the demo used
# when there was only ever one: as long as a letter is wide, a third as tall.
SHIP_SCALE = (0.5, 1.0)

# Dark, so they read as distant hardware against the sky rather than competing
# with the word.
SHIP_COLOURS = (
    (30, 55, 150),      # dark blue
    (150, 30, 35),      # dark red
    (175, 80, 15),      # dark orange
    (105, 35, 150),     # dark purple
)

# How many crossings may be in the sky at once. Not a style choice - a budget.
# The overlay runs once per DISPLAYED frame, and measured on an UNO Q at
# 480x1920 it costs about 14 ms per ship aloft; six of them came to 86 ms
# against the 66.7 ms a 15 fps frame allows, which drops frames and drags the
# whole scene. Four fits with room for the buffer copy and the write.
#
# The shortest interval paired with the longest crossing is what reaches six,
# so this is rare - and rare is exactly what makes it worth capping rather than
# leaving to be discovered in front of an audience. A launch that arrives while
# the sky is full is deferred, not dropped.
MAX_ALOFT = 4

# The exhaust: spheres per second, and the starting sizes they cycle through as
# a fraction of the base radius. Drawing a wireframe sphere is far dearer than
# filling one, and there is one stream per ship, so this is the other half of
# the frame budget.
PUFF_RATE = 7.0
PUFF_SIZES = (1.0, 0.55, 0.85, 0.40, 0.70, 0.48, 0.95, 0.62)

# 5x7, the same shape of font as show-number.sh. Only the letters of the word
# are here - there is no reason to carry an alphabet for one word.
FONT = {
    "A": ("01110", "10001", "10001", "11111", "10001", "10001", "10001"),
    "R": ("11110", "10001", "10001", "11110", "10100", "10010", "10001"),
    "D": ("11110", "10001", "10001", "10001", "10001", "10001", "11110"),
    "U": ("10001", "10001", "10001", "10001", "10001", "10001", "01110"),
    "I": ("11111", "00100", "00100", "00100", "00100", "00100", "11111"),
    "N": ("10001", "11001", "11001", "10101", "10011", "10011", "10001"),
    "O": ("01110", "10001", "10001", "10001", "10001", "10001", "01110"),
}


def _font_runs():
    """Each glyph as vertical runs of lit cells: (column, row, rows_tall).

    The word is drawn every displayed frame now, so what it costs per frame
    matters. Under the quarter turn a rect costs one slice per unit of logical
    WIDTH, so merging lit cells DOWN a column is free while merging along a row
    saves nothing. An A becomes eight runs instead of twenty-five cells, and
    the whole word lands at about a third of the price.
    """
    out = {}
    for ch, rows in FONT.items():
        runs = []
        for c in range(len(rows[0])):
            r = 0
            while r < len(rows):
                if rows[r][c] != "1":
                    r += 1
                    continue
                r0 = r
                while r < len(rows) and rows[r][c] == "1":
                    r += 1
                runs.append((c, r0, r - r0))
        out[ch] = tuple(runs)
    return out


FONT_RUNS = _font_runs()


class Canvas(object):
    """A framebuffer that can be drawn on as though it were turned sideways.

    Every primitive takes LOGICAL coordinates - the picture as it should look
    to someone standing in front of the panel - and writes physical pixels.
    """

    def __init__(self, pw, ph, stride, px, rot=0):
        self.pw, self.ph = pw, ph
        self.stride, self.px = stride, px
        self.rot = rot % 360
        if self.rot in (90, 270):
            self.w, self.h = ph, pw
        else:
            self.w, self.h = pw, ph
        self.buf = bytearray(stride * ph)

    def rect(self, x0, y0, x1, y1, col):
        """Fill a logical rectangle. The only primitive that touches memory."""
        if x1 < x0:
            x0, x1 = x1, x0
        if y1 < y0:
            y0, y1 = y1, y0
        if x0 < 0:
            x0 = 0
        if y0 < 0:
            y0 = 0
        if x1 > self.w:
            x1 = self.w
        if y1 > self.h:
            y1 = self.h
        if x1 <= x0 or y1 <= y0:
            return

        if self.rot == 90:
            pa, pb = self.pw - y1, self.pw - y0      # physical x range
            qa, qb = x0, x1                          # physical y range
        elif self.rot == 270:
            pa, pb = y0, y1
            qa, qb = self.ph - x1, self.ph - x0
        else:
            pa, pb = x0, x1
            qa, qb = y0, y1

        run = col * (pb - pa)
        n = (pb - pa) * self.px
        base = pa * self.px
        for q in range(qa, qb):
            o = q * self.stride + base
            self.buf[o:o + n] = run

    def run(self, y, xa, xb, col):
        self.rect(xa, y, xb, y + 1, col)

    def blk(self, x, y, th, col):
        h = th // 2
        self.rect(x - h, y - h, x - h + th, y - h + th, col)

    def line(self, x0, y0, x1, y1, th, col):
        """Bresenham. Used for the hulls; grid rows are single rects."""
        dx, dy = abs(x1 - x0), -abs(y1 - y0)
        sx = 1 if x0 < x1 else -1
        sy = 1 if y0 < y1 else -1
        err = dx + dy
        while True:
            self.blk(x0, y0, th, col)
            if x0 == x1 and y0 == y1:
                return
            e2 = 2 * err
            if e2 >= dy:
                err += dy
                x0 += sx
            if e2 <= dx:
                err += dx
                y0 += sy

    def ellipse(self, cx, cy, ax, ay, th, col):
        if ax < 1 or ay < 1:
            return
        n = max(24, int(6.3 * max(ax, ay) / 1.5))
        for i in range(n):
            a = 2.0 * math.pi * i / n
            self.blk(int(cx + ax * math.cos(a)),
                     int(cy + ay * math.sin(a)), th, col)


# --------------------------------------------------------------- the sun ---

def draw_sun(cv, cx, cy, r, col):
    """A wireframe sphere: the outline, lines of latitude, lines of longitude.

    The latitudes are what give it the banded vaporwave look; they are circles
    of latitude seen nearly edge on, so each is an ellipse that is wide and
    flat, and narrower the further it sits from the equator.
    """
    cv.ellipse(cx, cy, r, r, 3, col)
    for k in range(-3, 4):
        phi = k * (math.pi / 8.0)
        rr = r * math.cos(phi)
        if rr < r * 0.2:
            continue
        cv.ellipse(cx, int(cy + r * math.sin(phi)), int(rr),
                   max(2, int(rr * 0.22)), 2, col)
    for k in range(4):
        ax = r * math.sin(k * math.pi / 4.0 + math.pi / 8.0)
        cv.ellipse(cx, cy, max(1, int(abs(ax))), r, 2, col)


# ------------------------------------------------------------- the ships ---

# Wireframe sphere outlines, cached by integer radius. The exhaust holds a
# dozen spheres per ship whose radii change every frame, but there are only
# ever a few dozen distinct radii, and the trig is what costs.
_SPHERE_CACHE = {}


def sphere_points(r):
    """Offsets tracing a wireframe sphere: outline, one latitude, one
    longitude. Three ellipses is the fewest that still reads as a sphere."""
    pts = _SPHERE_CACHE.get(r)
    if pts is not None:
        return pts

    out = []

    def arc(ax, ay):
        if ax < 1 or ay < 1:
            return
        n = max(10, int(6.3 * max(ax, ay) / 1.8))
        for i in range(n):
            a = 2.0 * math.pi * i / n
            out.append((int(round(ax * math.cos(a))),
                        int(round(ay * math.sin(a)))))

    arc(r, r)
    arc(r * 0.94, r * 0.30)
    arc(r * 0.34, r * 0.97)

    pts = tuple(set(out))
    _SPHERE_CACHE[r] = pts
    return pts


def mesh_sphere(cv, cx, cy, r, th, col):
    if r < 2:
        return
    for dx, dy in sphere_points(r):
        cv.blk(cx + dx, cy + dy, th, col)


def draw_ship(cv, x_tip, y, length, height, th, col):
    """A wireframe triangle pointing the way it is going.

    The hull is the three edges; the mesh is ribs from the apex back to the
    base and bulkheads parallel to it. Half-height tapers linearly from base to
    apex, which is all the geometry either family of lines needs.
    """
    half = height / 2.0
    x_base = x_tip - length
    top, bot = y - half, y + half

    cv.line(int(x_tip), int(y), int(x_base), int(top), th, col)
    cv.line(int(x_tip), int(y), int(x_base), int(bot), th, col)
    cv.rect(int(x_base), int(top), int(x_base) + th, int(bot) + 1, col)

    for i in (1, 3):
        yb = top + (bot - top) * i / 4.0
        cv.line(int(x_tip), int(y), int(x_base), int(yb), th, col)

    for j in (1, 2, 3):
        d = length * j / 4.0
        hh = half * d / length
        x = int(x_tip - d)
        cv.rect(x, int(y - hh), x + th, int(y + hh) + 1, col)


class Ship(object):
    """One crossing: when it launches, how fast, how big, what colour, which
    side of the word it passes, and where along its base each sphere leaves.

    Everything is settled once, at launch. In particular a sphere's starting
    size and the point on the base it left from are keyed on its emission
    NUMBER, not on its position in the trail - keyed on position they would
    change as it drifted back, which is the difference between exhaust and a
    pattern crawling along a line.
    """

    def __init__(self, rng, launch, geom, full_len, full_h):
        self.launch = launch
        self.cross = rng.uniform(*SHIP_CROSS)

        f = rng.uniform(*SHIP_SCALE)
        self.length = max(6, int(full_len * f))
        self.height = max(3, int(full_h * f))

        self.colour = SHIP_COLOURS[rng.randrange(len(SHIP_COLOURS))]
        self.in_front = rng.random() < 0.5
        self.trail = 2 * self.length
        self.th = 2 if self.length > 60 else 1
        self.r_base = max(3, int(self.height * 0.40))

        # Somewhere in the band where the whole hull stays inside the sky.
        lo, hi = self.height, geom["horizon"] - self.height
        self.y = rng.uniform(lo, hi) if hi > lo else lo

        # So two ships in the sky at once do not exhaust in lock-step.
        self.puff_seed = rng.randrange(1 << 20)

    def draw(self, cv, elapsed, width, col):
        age = elapsed - self.launch
        reach = width + self.trail + self.length
        x_tip = -self.trail + (age / self.cross) * reach

        # A sphere stays where it was emitted while the ship flies on, so its
        # distance astern is just its age times the ship's speed. The trail
        # reaches exactly twice the hull with no bookkeeping beyond a lifetime.
        speed = reach / self.cross
        life = self.trail / speed

        half = self.height / 2.0
        emit = age * PUFF_RATE
        first = int(math.ceil(emit - life * PUFF_RATE))
        for m in range(first, int(emit) + 1):
            if m < 0:
                continue
            f = ((emit - m) / PUFF_RATE) / life
            if f >= 1.0:
                continue
            r = int(round(self.r_base * PUFF_SIZES[m % len(PUFF_SIZES)]
                          * (1.0 - f)))
            if r < 2:
                continue
            # Anywhere along the base, rather than all from one point of it.
            # A stable hash of the emission number, so a given sphere keeps
            # the place it left from for its whole life.
            h = (m * 2654435761 + self.puff_seed) & 0xFFFFF
            off = (h / float(0xFFFFF)) * 2.0 - 1.0
            mesh_sphere(cv,
                        int(x_tip - self.length - f * self.trail),
                        int(self.y + off * half + f * self.height * 0.30),
                        r, 1, col)

        draw_ship(cv, x_tip, self.y, self.length, self.height, self.th, col)


# ------------------------------------------------------------- the scene ---

def geometry(lw, lh):
    """Proportions, in logical (landscape) coordinates.

    Everything is a fraction of the logical frame, so the same scene composes
    on a 1920x480 bar and on a 1024x600 panel without a table of special cases.
    """
    # The vanishing point is the centre of the image, so the horizon is the
    # middle of the frame.
    horizon = int(lh * 0.50)

    # The sun sits a quarter of the width in from the right margin. With the
    # rays still converging dead centre, putting it off to one side is what
    # stops the frame reading as a diagram of perspective.
    sun_r = int(min(horizon * 0.23, lw * 0.08))
    sun_cx = int(lw * 0.75)
    sun_cy = int(horizon * 0.52)

    # The word is spread across the WHOLE frame rather than set as a block in
    # the middle: each letter owns an equal slice of the width and sits in the
    # centre of it. That is also what lets the letters be large - what bounds
    # them is now one slice, not the length of the whole word.
    margin = int(lw * 0.02)
    step = (lw - 2 * margin) / float(len(WORD))

    scale = max(2, int(min(step * 0.80 / 5.0, lh * 0.46 / 7.0)))
    half = 3.5 * scale
    letter_cy = int(lh * 0.44)

    amp = int(max(2, min(lh * 0.10,
                         (letter_cy - half) * 0.8,
                         (lh - (letter_cy + half)) * 0.8)))

    return {"horizon": horizon, "sun_r": sun_r, "sun_cx": sun_cx,
            "sun_cy": sun_cy, "scale": scale, "amp": amp,
            "letter_cy": letter_cy, "margin": margin, "step": step}


def base_frame(pw, ph, stride, px, rot, pack, geom):
    """Everything that never moves: the rays, the horizon, the sun."""
    cv = Canvas(pw, ph, stride, px, rot)
    horizon, sun_cy, sun_r = geom["horizon"], geom["sun_cy"], geom["sun_r"]
    cx = cv.w // 2

    purple = pack(*PURPLE)
    step = max(8, cv.w // 9)
    for i in range(-16, 17):
        cv.line(cx, horizon, cx + i * step, cv.h - 1, 1, purple)

    cv.run(horizon, 0, cv.w, pack(*HORIZON))
    cv.run(horizon + 1, 0, cv.w, pack(*HORIZON))

    draw_sun(cv, geom["sun_cx"], sun_cy, sun_r, pack(*ORANGE))
    return cv


def render(pw, ph, stride, bpp, rot, frames, depth_cycles, ratio):
    """The ring: grid rows over the static base. Nothing else loops."""
    px, pack = fbpaint.packer(bpp)

    probe = Canvas(pw, ph, stride, px, rot)
    lw, lh = probe.w, probe.h
    geom = geometry(lw, lh)
    horizon = geom["horizon"]

    base = base_frame(pw, ph, stride, px, rot, pack, geom)
    purple = pack(*PURPLE)

    depth = lh - horizon
    n_rows = 2
    while depth * (ratio ** n_rows) > 1.0 and n_rows < 48:
        n_rows += 1

    ring = []
    for n in range(frames):
        cv = Canvas(pw, ph, stride, px, rot)
        cv.buf = bytearray(base.buf)

        t = (n * depth_cycles / float(frames)) % 1.0
        for k in range(n_rows):
            off = depth * (ratio ** (k + 1.0 - t))
            y = int(horizon + off)
            th = 1 + int(2.0 * off / depth)
            cv.rect(0, y, lw, y + th, purple)

        ring.append(bytes(cv.buf))
        sys.stderr.write("\r  rendering %d/%d" % (n + 1, frames))
        sys.stderr.flush()

    sys.stderr.write("\r  rendered %d frames, %dx%d logical, %d grid rows   \n"
                     % (frames, lw, lh, n_rows))
    return ring, geom


def make_overlay(pw, ph, stride, px, rot, pack, geom, seed=None,
                 wave_period=4.0, colour_period=6.0):
    """Return the overlay: ships behind, then the word, then ships in front.

    The word lives here rather than in the ring precisely so that something can
    pass behind it. Everything here runs on wall-clock time, which is also what
    lets the ships keep intervals far longer than the ring is.
    """
    cv = Canvas(pw, ph, stride, px, rot)
    scale = geom["scale"]
    margin, step = geom["margin"], geom["step"]
    letter_cy, amp = geom["letter_cy"], geom["amp"]
    black = pack(0, 0, 0)

    full_len = 5 * scale
    full_h = max(3, int(7 * scale / 3.0))

    rng = random.Random(seed)
    fleet = []
    state = {"next": rng.uniform(*SHIP_EVERY)}

    # Packed once. pack() builds a bytes object, and the sphere loop would
    # otherwise ask for one per sphere per frame.
    packed = {c: pack(*c) for c in SHIP_COLOURS}

    def letters(elapsed):
        ang0 = 2.0 * math.pi * elapsed / wave_period
        for i, ch in enumerate(WORD):
            dy = amp * math.sin(ang0 - i * 2.0 * math.pi / len(WORD))
            x0 = int(margin + (i + 0.5) * step - 2.5 * scale)
            y0 = int(letter_cy - 3.5 * scale + dy)
            hue = 360.0 * (i / float(len(WORD)) + elapsed / colour_period)
            col = pack(*fbpaint.hsv_to_rgb(hue, 0.85, 1.0))
            runs = FONT_RUNS[ch]
            # A dark skirt under the whole glyph first, so a letter stays
            # readable where it crosses the grid or a ship - then the glyph.
            for c, r, n in runs:
                x, y = x0 + c * scale, y0 + r * scale
                cv.rect(x - 1, y - 1, x + scale + 1, y + n * scale + 1, black)
            for c, r, n in runs:
                x, y = x0 + c * scale, y0 + r * scale
                cv.rect(x, y, x + scale, y + n * scale, col)

    def overlay(buf, elapsed):
        cv.buf = buf

        # Retire anything that has finished crossing, then launch what is due.
        # Retiring first so a ship leaving the frame frees its slot in the same
        # tick that the next one wants it.
        if fleet:
            fleet[:] = [s for s in fleet if elapsed - s.launch < s.cross]
        while state["next"] <= elapsed:
            if len(fleet) >= MAX_ALOFT:
                # Sky full: hold this one back rather than lose it, and try
                # again shortly.
                state["next"] = elapsed + 1.0
                break
            fleet.append(Ship(rng, state["next"], geom, full_len, full_h))
            state["next"] += rng.uniform(*SHIP_EVERY)

        for s in fleet:
            if not s.in_front:
                s.draw(cv, elapsed, cv.w, packed[s.colour])

        letters(elapsed)

        for s in fleet:
            if s.in_front:
                s.draw(cv, elapsed, cv.w, packed[s.colour])

    return overlay


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--width", type=int, required=True)
    ap.add_argument("--height", type=int, required=True)
    ap.add_argument("--stride", type=int, required=True)
    ap.add_argument("--bpp", type=int, default=32)
    ap.add_argument("--rotate", type=int, default=0, choices=(0, 90, 180, 270),
                    help="turn the scene, for a panel mounted on its side")
    ap.add_argument("--seconds", type=float, default=600.0)
    ap.add_argument("--fps", type=float, default=15.0)
    ap.add_argument("--frames", type=int, default=48)
    ap.add_argument("--ratio", type=float, default=0.78,
                    help="spacing between grid rows, toward the horizon")
    ap.add_argument("--depth-cycles", type=int, default=3)
    ap.add_argument("--seed", type=int, default=None,
                    help="fix the fleet, for a run that repeats exactly")
    ap.add_argument("--vt", default="")
    ap.add_argument("--hold", action="store_true")
    ap.add_argument("--until-touch", action="store_true")
    args = ap.parse_args()

    frames = fbpaint.frame_budget(args.height, args.stride, args.frames)
    ring, geom = render(args.width, args.height, args.stride, args.bpp,
                        args.rotate, frames, args.depth_cycles, args.ratio)

    px, pack = fbpaint.packer(args.bpp)
    seed = args.seed if args.seed is not None else int(time.time())
    overlay = make_overlay(args.width, args.height, args.stride, px,
                           args.rotate, pack, geom, seed=seed)

    sys.exit(fbpaint.play(ring, fps=args.fps, seconds=args.seconds,
                          vt=args.vt, hold=args.hold,
                          until_touch=args.until_touch, overlay=overlay))


if __name__ == "__main__":
    main()

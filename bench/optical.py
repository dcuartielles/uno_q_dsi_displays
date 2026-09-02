#!/usr/bin/env python3
"""Optical ground truth for the UNO Q panel benchmark.

Why this exists
---------------
Nothing in software can tell you whether the panel is actually working:

  * The panel controller's registers do not read back what you write. PORTB and
    PORTC return a fixed 0x85 / 0x10 whatever you send, the same quirk that
    broke mainline's is_enabled().
  * A DRM connector can report "connected", carry a mode and scan out a
    framebuffer while the screen is completely dark. That exact combination is
    the failure that took longest to find.
  * The backlight cannot even be switched off from software. brightness=0 and
    bl_power=1 both only dim it, because this panel has a deliberately visible
    minimum brightness. So "the driver says the backlight is off" proves
    nothing either.

So the benchmark needs eyes.

Three traps this module is built around
---------------------------------------
1. AUTO-EXPOSURE. Webcams compensate: when the panel goes dark the camera opens
   up and the whole frame brightens. Measured naively, a dark panel scores
   HIGHER than a lit one - we measured exactly that inversion. So absolute
   luminance is never used. Every metric is the panel measured RELATIVE to the
   background around it, which auto-exposure scales equally.

   (Locking exposure is worse: asking DSHOW for manual exposure produced an
   almost black frame, RGB around (3, 0, 2). It is off by default.)

2. BRIGHTNESS IS A POOR SUCCESS SIGNAL. The Arduino login screen is mostly dark
   blue. Calibrated against solid white, a perfectly good boot measured
   "dark" - a false failure. What separates a working screen from a blank one
   is STRUCTURE, not brightness: measured here, the login screen scored 13.1
   edge energy against 1.9 for solid white, a 7x margin. Brightness is only
   used to answer "is the panel emitting at all".

3. PWM FLICKER. The backlight is PWM-dimmed, so a single frame can land in a
   dark part of the duty cycle. Every capture is the median of several frames.

Usage
-----
    optical.py devices
    optical.py calibrate --camera 1 [--dark-cmd ... --solid-cmd ... --content-cmd ...]
    optical.py check --expect image        # the boot success criterion
    optical.py check --expect colour --colour red
"""
import argparse
import json
import math
import os
import shutil
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
DEFAULT_CAL = os.path.join(HERE, "optical-cal.json")

try:
    import cv2
    import numpy as np
except ImportError:  # pragma: no cover
    sys.exit("optical.py needs opencv-python and numpy:\n"
             "    python -m pip install opencv-python numpy")


def run_shell(cmd):
    """Run a shell command portably.

    On Windows os.system() hands the string to cmd.exe, which mangles the POSIX
    quoting these commands use. Prefer a real sh when one is on PATH (Git for
    Windows ships one).
    """
    sh = shutil.which("sh")
    if sh:
        return subprocess.run([sh, "-c", cmd]).returncode
    return os.system(cmd)


# --------------------------------------------------------------- capture ---
def open_camera(index, warmup=30, width=1280, height=720, lock_exposure=False):
    """Open a camera and discard the first frames while exposure settles.

    The warm-up is deliberately long (~1.5s). A webcam needs a second or two of
    continuous reading to adapt after a big scene change, and reading only a
    handful of frames produced a calibration where solid white measured DIMMER
    than the login screen - the exposure had simply not caught up yet.
    """
    backend = cv2.CAP_DSHOW if sys.platform == "win32" else cv2.CAP_ANY
    cap = cv2.VideoCapture(index, backend)
    if not cap.isOpened():
        cap.release()
        return None
    cap.set(cv2.CAP_PROP_FRAME_WIDTH, width)
    cap.set(cv2.CAP_PROP_FRAME_HEIGHT, height)
    if lock_exposure:
        cap.set(cv2.CAP_PROP_AUTO_EXPOSURE, 0.25)
        cap.set(cv2.CAP_PROP_AUTO_WB, 0)
    for _ in range(warmup):
        cap.read()
        time.sleep(0.05)
    return cap


def grab(cap, samples=7):
    """Median of several frames, rejecting sensor noise and PWM flicker."""
    frames = []
    for _ in range(samples):
        ok, frame = cap.read()
        if ok and frame is not None:
            frames.append(frame.astype(np.float32))
        time.sleep(0.04)
    if not frames:
        return None
    return np.median(np.stack(frames), axis=0)


def capture(index, samples=7):
    cap = open_camera(index)
    if cap is None:
        return None
    frame = grab(cap, samples=samples)
    cap.release()
    return frame


def list_devices(max_index=6):
    found = []
    for i in range(max_index):
        cap = open_camera(i, warmup=2)
        if cap is None:
            continue
        frame = grab(cap, samples=2)
        cap.release()
        if frame is not None:
            h, w = frame.shape[:2]
            found.append({"index": i, "width": int(w), "height": int(h),
                          "mean_luma": round(float(luminance(frame).mean()), 1)})
    return found


# --------------------------------------------------------------- measure ---
def luminance(frame):
    """Rec. 601 luma, matching how the eye weights the channels."""
    b, g, r = frame[..., 0], frame[..., 1], frame[..., 2]
    return 0.299 * r + 0.587 * g + 0.114 * b


def normalised(lum):
    """Scale a frame by its own median, making it exposure-invariant.

    If the camera doubles its gain every pixel doubles and so does the median,
    leaving the normalised frame unchanged.
    """
    return lum / max(float(np.median(lum)), 1.0)


def edge_energy(lum, mask):
    """How much structure is inside the panel region.

    This is the metric that separates "showing an image" from "backlight on,
    nothing rendered". A login screen or a desktop has edges; a uniform glow
    does not.

    The denominator is floored: on a dark panel the mean tends to zero and the
    ratio explodes, which once made a black screen score higher than a busy
    one. Callers must ALSO gate on the panel being lit - see check().
    """
    # Blur first. Sensor noise is per-pixel, real UI structure spans tens of
    # pixels, so a small Gaussian removes the former and keeps the latter.
    # Without it, DIM solid colours scored highest of all: dividing by mean**2
    # amplifies read noise as the mean falls, and solid red measured edge 19.2
    # against 2.0 for solid white - the opposite of the truth.
    lum = cv2.GaussianBlur(lum.astype(np.float32), (0, 0), 2.0)
    lap = cv2.Laplacian(lum, cv2.CV_32F, ksize=3)
    mean = max(float(lum[mask].mean()), 8.0)
    return float(lap[mask].var()) / mean ** 2 * 1000.0


def measure(frame, cal):
    """Exposure-invariant measurements inside the calibrated panel region."""
    mask = np.array(cal["mask"], dtype=bool)
    bg = np.array(cal["background"], dtype=bool)
    lum = luminance(frame)
    if mask.shape != lum.shape:
        raise SystemExit(
            "calibration was captured at %s but the camera now gives %s - "
            "re-run 'optical.py calibrate'" % (mask.shape, lum.shape))

    panel_luma = float(lum[mask].mean())
    bg_luma = float(lum[bg].mean())
    px = frame[mask]
    return {
        "contrast": panel_luma / max(bg_luma, 1.0),
        "edge": edge_energy(lum, mask),
        "panel_luma": panel_luma,
        "bg_luma": bg_luma,
        "b": float(px[:, 0].mean()),
        "g": float(px[:, 1].mean()),
        "r": float(px[:, 2].mean()),
    }


def classify(contrast, cal):
    """Is the panel emitting light at all?

    Deliberately only dark/lit. An earlier version had a middle "dim" state
    with thresholds derived from solid white, and it called the real Arduino
    login screen "dark". Brightness only has to answer "is it on".
    """
    return "lit" if contrast >= cal["threshold_lit"] else "dark"


def dominant_colour(m):
    """Which channel dominates, or None when the panel is roughly neutral.

    A 15% margin over both other channels: loose enough to survive a webcam's
    white balance, tight enough that white or grey is not read as a primary.
    """
    r, g, b = m["r"], m["g"], m["b"]
    if r > g * 1.15 and r > b * 1.15:
        return "red"
    if g > r * 1.15 and g > b * 1.15:
        return "green"
    if b > r * 1.15 and b > g * 1.15:
        return "blue"
    return None


def panel_region(delta, erode_px=9):
    """Turn a raw brightness difference into a clean, solid panel region.

    Thresholding alone gives a speckled mask, and sampling the Laplacian at
    scattered pixels measures sensor noise rather than picture content: it once
    scored a uniform white screen at edge 16.3, higher than a real desktop.

    So: threshold, close the gaps, keep only the LARGEST connected component
    (the panel, not a reflection on the table), fill its holes, then erode a
    little so the bezel boundary - which is a genuine, permanent edge - is
    excluded from the structure measurement.
    """
    thresh = max(10.0, float(delta.max()) * 0.35)
    raw = (delta > thresh).astype(np.uint8)

    k = np.ones((7, 7), np.uint8)
    raw = cv2.morphologyEx(raw, cv2.MORPH_OPEN, k)
    raw = cv2.morphologyEx(raw, cv2.MORPH_CLOSE, np.ones((15, 15), np.uint8))

    n, labels, stats, _ = cv2.connectedComponentsWithStats(raw, connectivity=8)
    if n <= 1:
        return raw.astype(bool)
    # label 0 is the background
    biggest = 1 + int(np.argmax(stats[1:, cv2.CC_STAT_AREA]))
    comp = (labels == biggest).astype(np.uint8)

    # Fill interior holes: dark UI areas inside the panel still belong to it.
    filled = comp.copy()
    h, w = filled.shape
    ff = np.zeros((h + 2, w + 2), np.uint8)
    cv2.floodFill(filled, ff, (0, 0), 1)
    comp = comp | (1 - filled)

    # Pull back from the bezel so its hard edge is not counted as picture
    # structure - otherwise a blank screen scores like a busy one.
    comp = cv2.erode(comp, np.ones((erode_px, erode_px), np.uint8))
    return comp.astype(bool)


def _gm(a, b):
    """Geometric mean - the right midpoint between two ratio-like values."""
    return math.sqrt(max(a, 1e-6) * max(b, 1e-6))


# ------------------------------------------------------------- calibrate ---
def calibrate(args):
    """Learn where the panel is, and what working looks like.

    Three references, because two are not enough:

      dark     black at minimum backlight - as close to off as this panel gets
      solid    full white: LIT BUT FEATURELESS, i.e. exactly the "backlight on,
               nothing rendered" failure we need to be able to catch
      content  what the board actually shows when it boots - a real display

    Thresholds sit at the geometric mean of the neighbouring references:

      threshold_lit  = gm(dark.contrast, content.contrast)
      threshold_edge = gm(solid.edge,    content.edge)
    """
    print("Point the camera at the panel so it fills a good part of the frame.")
    print("Keep the room lighting constant for the whole benchmark run.")
    print("")

    def get_state(cmd, prompt):
        if cmd:
            print("  %s" % cmd)
            run_shell(cmd)
            time.sleep(args.settle)
        else:
            input(prompt)
        f = capture(args.camera, samples=9)
        if f is None:
            sys.exit("could not capture from camera %d" % args.camera)
        return f

    dark = get_state(args.dark_cmd,
                     "1/3  Panel BLACK (or board off / covered), press Enter... ")
    solid = get_state(args.solid_cmd,
                      "2/3  Panel solid WHITE, press Enter... ")
    content = get_state(args.content_cmd,
                        "3/3  Panel showing the normal boot screen, press Enter... ")

    # The panel is whatever got brighter between black and white.
    delta = luminance(solid) - luminance(dark)
    mask = panel_region(delta)
    frac = float(mask.mean())
    if frac < 0.01:
        sys.exit(
            "the panel region came out at %.2f%% of the frame - too small. "
            "Either the camera does not really see the panel, or it did not "
            "change between the two captures. Note brightness=0 only DIMS this "
            "panel: use the black/white patterns, or power the board off."
            % (frac * 100))

    # Background: well clear of the panel, so bezel glow and reflections on the
    # table do not contaminate the reference.
    k = np.ones((41, 41), np.uint8)
    near = cv2.dilate(mask.astype(np.uint8), k, iterations=1).astype(bool)
    background = ~near
    if background.mean() < 0.05:
        background = ~mask

    cal = {"camera": args.camera, "shape": list(mask.shape),
           "panel_fraction": frac,
           "mask": mask.tolist(), "background": background.tolist()}

    m_dark = measure(dark, cal)
    m_solid = measure(solid, cal)
    m_content = measure(content, cal)

    cal.update({
        "dark_contrast": m_dark["contrast"],
        "solid_contrast": m_solid["contrast"],
        "content_contrast": m_content["contrast"],
        "solid_edge": m_solid["edge"],
        "content_edge": m_content["edge"],
        "threshold_lit": _gm(m_dark["contrast"], m_content["contrast"]),
        "threshold_edge": _gm(m_solid["edge"], m_content["edge"]),
    })

    with open(args.cal, "w") as fh:
        json.dump(cal, fh)

    print("")
    print("calibration written to %s" % args.cal)
    print("  panel occupies %.1f%% of the frame" % (frac * 100))
    print("  contrast:  dark %.2f | content %.2f | solid %.2f"
          % (m_dark["contrast"], m_content["contrast"], m_solid["contrast"]))
    print("  edge:      solid %.2f | content %.2f"
          % (m_solid["edge"], m_content["edge"]))
    print("  thresholds: lit >= %.2f, image >= %.2f"
          % (cal["threshold_lit"], cal["threshold_edge"]))

    ratio = m_content["edge"] / max(m_solid["edge"], 1e-6)
    if ratio < 2:
        print("")
        print("  WARNING: the boot screen is only %.1fx more structured than a"
              % ratio)
        print("  blank one. Focus the camera better or fill more of the frame,")
        print("  or 'lit but nothing rendered' will not be caught reliably.")
    if m_content["contrast"] < m_dark["contrast"] * 3:
        print("")
        print("  WARNING: the boot screen is barely brighter than the dark")
        print("  reference. Reduce the room lighting.")
    return 0


# ----------------------------------------------------------------- check ---
def load_cal(path):
    if not os.path.exists(path):
        sys.exit("no calibration at %s - run 'optical.py calibrate' first" % path)
    with open(path) as fh:
        return json.load(fh)


def check(args):
    cal = load_cal(args.cal)
    cam = args.camera if args.camera is not None else cal["camera"]
    frame = capture(cam, samples=args.samples)
    if frame is None:
        sys.exit("could not capture from camera %s" % cam)

    m = measure(frame, cal)
    state = classify(m["contrast"], cal)
    colour = dominant_colour(m)
    # Structure is gated on the panel emitting: edge energy is meaningless on a
    # black screen, where tiny absolute values dominate the ratio.
    has_image = state != "dark" and m["edge"] >= cal.get("threshold_edge", 0.0)

    result = {
        "state": state,
        "has_image": bool(has_image),
        "contrast": round(m["contrast"], 3),
        "edge": round(m["edge"], 3),
        "rgb": [round(m["r"], 1), round(m["g"], 1), round(m["b"], 1)],
        "dominant_colour": colour,
    }

    if args.expect == "image":
        result["pass"] = bool(has_image)
    elif args.expect == "lit":
        result["pass"] = state == "lit"
    elif args.expect == "dark":
        result["pass"] = state == "dark"
    elif args.expect == "colour":
        result["pass"] = state != "dark" and colour == args.colour
        result["expected_colour"] = args.colour
    else:
        result["pass"] = None

    if args.save:
        cv2.imwrite(args.save, frame.astype(np.uint8))
        result["frame"] = args.save

    print(json.dumps(result))
    return 0 if result["pass"] in (True, None) else 1


# ------------------------------------------------------------------ main ---
def main():
    ap = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)

    p = sub.add_parser("devices", help="list usable cameras")
    p.set_defaults(func=lambda a: (print(json.dumps(list_devices(), indent=2)), 0)[1])

    p = sub.add_parser("calibrate", help="learn the panel and what working looks like")
    p.add_argument("--camera", type=int, default=0)
    p.add_argument("--cal", default=DEFAULT_CAL)
    p.add_argument("--dark-cmd", help="command showing BLACK at minimum backlight")
    p.add_argument("--solid-cmd", help="command showing solid WHITE")
    p.add_argument("--content-cmd", help="command restoring the normal boot screen")
    p.add_argument("--settle", type=float, default=3.0)
    p.set_defaults(func=calibrate)

    p = sub.add_parser("check", help="capture one frame and judge it")
    p.add_argument("--camera", type=int, default=None)
    p.add_argument("--cal", default=DEFAULT_CAL)
    p.add_argument("--expect", choices=["image", "lit", "dark", "colour", "none"],
                   default="none")
    p.add_argument("--colour", choices=["red", "green", "blue"], default="red")
    p.add_argument("--samples", type=int, default=7)
    p.add_argument("--save", help="write the captured frame here")
    p.set_defaults(func=check)

    args = ap.parse_args()
    sys.exit(args.func(args))


if __name__ == "__main__":
    main()

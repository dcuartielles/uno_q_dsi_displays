<!--
Adding a panel? CONTRIBUTING.md explains why each of these is asked for.
Fixing something else? Delete this and describe the change.
-->

## The panel

- **Name / where to buy it:**
- **Resolution and size:**
- **Integration path:** stock / described / derived
- **Board and image it was tested on:** (`uname -r`, carrier status)

## Detection

Paste `sudo ./scripts/detect-panel.sh` — it should show your panel matched and
every other one rejected, with the reason:

```

```

Paste `python3 tools/check-fingerprints.py -v`:

```

```

- [ ] `bench/results/goodix/<name>.txt` is included, so CI can replay it
- [ ] no probe reads more than 12 bytes (the CCI limit)
- [ ] every probe stage rules something out

## It actually works

- **DRM connector / mode:**
- **Driver that bound:**
- **Photograph of the panel running:** (drag it in — a number or the spiral on
  the glass; every software check here can pass while the screen shows garbage)
- **Touch confirmed with a finger:** yes / no / the panel has none

## Honesty

Anything guessed rather than measured, and anything still unverified. Say it
here and in the `.panel` file — a note that something is unchecked is worth
more than a confident wrong value.

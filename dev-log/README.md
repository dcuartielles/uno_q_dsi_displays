# dev-log — the raw investigation

> **Read this first.** Nothing in this directory is required to use the
> repository, and **parts of it are wrong**. It is the unedited record of
> getting the first panel working, kept because the wrong turns are often more
> instructive than the answer. For what is actually true, read
> [../docs/HOW-IT-WORKS.md](../docs/HOW-IT-WORKS.md).

The scripts here were written to be run one at a time against a board on a
desk, taking credentials on stdin. They are not general-purpose, they are not
idempotent, and several of them deliberately break the machine to see what
happens. Do not run them.

## Conclusions in these notes that were later disproved

| Claim you will find in here | What is actually true |
| --- | --- |
| The panel needs a 5 V feed the DSI connector does not carry | Wrong. The panel is powered from +3V3 on pin 22 of the DSI FPC. There is no missing 5 V rail. |
| The DSI connector cannot supply the panel's ~360 mA | Wrong. Pin 22 is tied straight to `PWR_3P3V`; current was never the limit. |
| `dsi_err_worker: status=4` means a DLN0 PHY error | Wrong. In *this* kernel's constants, 4 is a FIFO status and is largely benign. |
| The panel carries a Toshiba TC358762 bridge (v1, v2 overlays) | Wrong. It is a Chipone ICN6211, which self-configures — so no bridge node belongs in the device tree at all. |
| A new DSI cable fixed the I²C errors | Wrong attribution. The attiny write-retry patch was the actual fix; the cable swap happened to coincide with it. |

The v1/v2/v3 device trees in `dt/` are kept for the same reason — they are the
wrong topologies, in order. The working one is `../dt/`.

## What the numbered notes cover

| File | Subject |
| --- | --- |
| `docs/01-connect.md` | first contact with the board, credentials, ADB and SSH |
| `docs/02-update.md` | updating a launch-era image to a kernel with carrier support |
| `docs/03-panel-identified.md` | identifying the panel and its bridge |
| `docs/04-bringup-log.md` | the bring-up attempts, in order, including the failures |
| `docs/05-working-configuration.md` | the first configuration that produced a picture |
| `docs/06-rpi-parity.md` | diffing the Raspberry Pi drivers against mainline — where the real answers came from |
| `docs/baseline*.txt` | machine state before and after the OS update |

Local addresses, network names and credentials have been replaced with
placeholders such as `<BOARD-IP>`.

# Shared helpers. Sourced by every script in scripts/.
# POSIX sh - runs on the UNO Q's Debian.

# ---------------------------------------------------------------- output ----
if [ -t 1 ]; then
    C_RED=$(printf '\033[31m'); C_GRN=$(printf '\033[32m')
    C_YEL=$(printf '\033[33m'); C_BLU=$(printf '\033[36m')
    C_BLD=$(printf '\033[1m');  C_OFF=$(printf '\033[0m')
else
    C_RED=; C_GRN=; C_YEL=; C_BLU=; C_BLD=; C_OFF=
fi

say()  { printf '%s\n' "$*"; }
step() { printf '\n%s==> %s%s\n' "$C_BLD$C_BLU" "$*" "$C_OFF"; }
ok()   { printf '%s  ok%s  %s\n' "$C_GRN" "$C_OFF" "$*"; }
warn() { printf '%s  !!%s  %s\n' "$C_YEL" "$C_OFF" "$*"; }
die()  { printf '%s ERROR%s %s\n' "$C_RED" "$C_OFF" "$*" >&2; exit 1; }

# ------------------------------------------------------------- constants ----
DTB_DIR=/boot/efi/dtb/qcom
BASE_DTB="$DTB_DIR/qrb2210-arduino-imola-base.dtb"
CARRIER_DTBO="$DTB_DIR/qrb2210-arduino-imola-carrier-media.dtbo"

# We reuse Arduino's 5-inch display slot: arduino-linux-config hardcodes its
# option names and .dtbo filenames inside its Go binary, so a new option cannot
# be registered. Our overlay is installed in this slot and selected with
# display=5-dsi-touch-a. The original is preserved as .arduino-orig.
SLOT_DTBO="$DTB_DIR/qrb2210-arduino-imola-carrier-media-panel-5in_touch_a-dsi.dtbo"
SLOT_BACKUP="$SLOT_DTBO.arduino-orig"
CARRIER_DISPLAY_OPTION="5-dsi-touch-a"

BUILD_DIR="${BUILD_DIR:-$HOME/.uno-q-dsi-build}"
STATE_DIR=/var/lib/uno-q-dsi-panel

# ----------------------------------------------------------------- checks ----
need_root() {
    [ "$(id -u)" -eq 0 ] || die "run this with sudo: sudo $0 $*"
}

is_uno_q() {
    tr -d '\0' < /proc/device-tree/model 2>/dev/null \
        | grep -qiE 'unoq|uno q|imola|ventuno'
}

# Absolute path for a file, so it survives a later cd.
abspath() {
    _d=$(dirname -- "$1"); _f=$(basename -- "$1")
    printf '%s/%s\n' "$(CDPATH= cd -- "$_d" && pwd)" "$_f"
}

kernel_has_carrier_overlays() {
    [ -f "$CARRIER_DTBO" ] && [ -f "$BASE_DTB" ]
}

have_cmd() { command -v "$1" >/dev/null 2>&1; }

# --------------------------------------------------------- panel defs -------
# Load a .panel definition and validate the fields the generators rely on.
load_panel() {
    _p=$1
    [ -f "$_p" ] || die "panel definition not found: $_p"
    # shellcheck disable=SC1090
    . "$_p"
    for _v in PANEL_ID PANEL_COMPATIBLE PANEL_C_NAME CLOCK_KHZ \
              HACTIVE HFRONT HSYNC HBACK VACTIVE VFRONT VSYNC VBACK \
              DSI_LANES DSI_FORMAT DSI_MODE_FLAGS BPC; do
        eval "_val=\$$_v"
        [ -n "$_val" ] || die "$_p: missing required field $_v"
    done
    : "${WIDTH_MM:=0}" "${HEIGHT_MM:=0}"
    : "${PANEL_CTRL_COMPATIBLE:=raspberrypi,7inch-touchscreen-panel-regulator}"
    : "${PANEL_CTRL_ADDR:=0x45}"
    : "${TOUCH_ADDR:=}"
}

# ------------------------------------------------------------ bookkeeping ---
record_state() {
    mkdir -p "$STATE_DIR"
    printf '%s\n' "$*" >> "$STATE_DIR/installed.txt"
}

# Back up an in-tree module once, before we replace it.
backup_module() {
    _m=$1
    [ -f "$_m" ] || return 0
    [ -f "$_m.distrib" ] || cp -a "$_m" "$_m.distrib"
}

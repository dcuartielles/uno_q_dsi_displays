#!/bin/sh
# Runs ON the UNO Q. Stdin secrets contract: 1. sudo password  2. SSID  3. wifi pw
#
# Stage 5: build the two mainline drivers kernel 7.0 does not ship but our
# 800x480 TC358762 panel needs:
#   drivers/gpu/drm/bridge/tc358762.c            (DSI -> DPI bridge)
#   drivers/regulator/rpi-panel-attiny-regulator.c (ATTINY @0x45: power + backlight)
#
# Sources come from Arduino's own kernel fork at the exact commit our kernel was
# built from: uname -r is 7.0.0-g122c2c22d838, so the commit is 122c2c22d838.
unset HISTFILE

IFS= read -r SUDO_PASS; SUDO_PASS=$(printf '%s' "$SUDO_PASS" | tr -d '\r')
IFS= read -r WIFI_SSID
IFS= read -r WIFI_PASS

S() { printf '%s\n' "$SUDO_PASS" | sudo -S -p '' "$@"; }
S true 2>/dev/null || { echo "SUDO PASSWORD REJECTED"; exit 1; }

K=$(uname -r)
COMMIT=$(printf '%s' "$K" | sed 's/.*-g//')
BUILD=$HOME/panel-build
REPO=https://raw.githubusercontent.com/arduino/linux-qcom

echo "=== kernel $K -> source commit $COMMIT ==="
[ -d "/lib/modules/$K/build" ] || { echo "ERROR: no build tree at /lib/modules/$K/build"; exit 1; }

mkdir -p "$BUILD"
cd "$BUILD" || exit 1

fetch() {
    url=$1; out=$2
    if command -v curl >/dev/null 2>&1; then
        curl -fsSL "$url" -o "$out" 2>/dev/null && return 0
    fi
    if command -v wget >/dev/null 2>&1; then
        wget -q "$url" -O "$out" 2>/dev/null && return 0
    fi
    return 1
}

get_source() {
    path=$1; out=$2
    for ref in "$COMMIT" v7.0 main master; do
        echo "  trying ref $ref ..."
        if fetch "$REPO/$ref/$path" "$out"; then
            # a GitHub 404 page would not start with a license comment
            if head -3 "$out" | grep -q '//\|/\*'; then
                echo "  OK: $out ($(wc -l < "$out") lines, from ref $ref)"
                return 0
            fi
        fi
        rm -f "$out"
    done
    return 1
}

echo
echo "=== fetching tc358762.c ==="
get_source drivers/gpu/drm/bridge/tc358762.c tc358762.c || { echo "FAILED to fetch tc358762.c"; exit 1; }

echo
echo "=== fetching rpi-panel-attiny-regulator.c ==="
get_source drivers/regulator/rpi-panel-attiny-regulator.c rpi-panel-attiny-regulator.c \
    || { echo "FAILED to fetch rpi-panel-attiny-regulator.c"; exit 1; }

echo
echo "=== writing Makefile ==="
cat > Makefile <<'MAKEFILE_EOF'
obj-m += tc358762.o
obj-m += rpi-panel-attiny-regulator.o

KDIR ?= /lib/modules/$(shell uname -r)/build

all:
	$(MAKE) -C $(KDIR) M=$(PWD) modules

clean:
	$(MAKE) -C $(KDIR) M=$(PWD) clean
MAKEFILE_EOF
cat Makefile

echo
echo "=== building ==="
make -C "/lib/modules/$K/build" M="$BUILD" modules 2>&1 | tail -40

echo
echo "=== results ==="
ls -la "$BUILD"/*.ko 2>/dev/null || echo ">>> NO MODULES BUILT"

if [ -f "$BUILD/tc358762.ko" ] && [ -f "$BUILD/rpi-panel-attiny-regulator.ko" ]; then
    echo
    echo "=== installing into /lib/modules/$K/extra ==="
    S mkdir -p "/lib/modules/$K/extra"
    S cp "$BUILD/tc358762.ko" "$BUILD/rpi-panel-attiny-regulator.ko" "/lib/modules/$K/extra/"
    S depmod -a
    echo
    echo "=== verify modinfo + aliases ==="
    modinfo tc358762 2>&1 | head -8
    echo "---"
    modinfo rpi-panel-attiny-regulator 2>&1 | head -8
    echo
    echo "=== compatible strings the new modules claim ==="
    grep -iE "tc358762|attiny|7inch" "/lib/modules/$K/modules.alias" | head -10
    echo
    echo "=== test load ==="
    S modprobe tc358762 2>&1 && echo "tc358762 loaded" || echo "tc358762 load failed"
    S modprobe rpi-panel-attiny-regulator 2>&1 && echo "attiny regulator loaded" || echo "attiny load failed"
    lsmod | grep -iE "tc358762|attiny"
else
    echo ">>> build did not produce both modules; not installing"
fi

echo
echo "=== stage 5 done ==="

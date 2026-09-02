#!/bin/sh
# Runs ON the UNO Q. Stdin secrets contract: 1. sudo password  2. SSID  3. wifi pw
#
# REVERSE ENGINEERING, STEP 4: automated write probe with a machine oracle.
#
# The controller at 0x45 drives the touch chip's reset (RST_TP_N on the RPi
# design). So instead of asking a human to watch a dim panel, use the TOUCH
# CHIP at 0x38 as the detector: write a candidate register/value to 0x45, then
# see whether the touch chip's registers changed. Any change means that write
# really did something to the panel's control lines.
#
# Secondary oracles: 0x45's own readable registers (0x80/0x82/0x83).
#
# Probes the neighbourhoods of the three documented protocols first, since a
# variant firmware usually keeps its registers near the original.
unset HISTFILE
IFS= read -r SUDO_PASS; SUDO_PASS=$(printf '%s' "$SUDO_PASS" | tr -d '\r')
IFS= read -r WIFI_SSID
IFS= read -r WIFI_PASS
S() { printf '%s\n' "$SUDO_PASS" | sudo -S -p '' "$@"; }
S true 2>/dev/null || { echo "SUDO PASSWORD REJECTED"; exit 1; }

B=$(basename "$(ls -d /sys/bus/i2c/devices/*-0045 2>/dev/null | head -1)" | cut -d- -f1)
echo "bus=$B"

S sh -c "
BUS=$B

touch_state() { i2ctransfer -f -y \$BUS w1@0x38 0x00 r8 2>/dev/null; }
ctrl_state()  { printf '%s %s %s' \
    \"\$(i2cget -f -y \$BUS 0x45 0x80 2>/dev/null)\" \
    \"\$(i2cget -f -y \$BUS 0x45 0x82 2>/dev/null)\" \
    \"\$(i2cget -f -y \$BUS 0x45 0x83 2>/dev/null)\"; }

base_t=\$(touch_state); base_c=\$(ctrl_state)
echo \"baseline touch : \$base_t\"
echo \"baseline ctrl  : \$base_c\"
echo

hits=0; probes=0
probe() {
    reg=\$1; val=\$2
    i2cset -f -y \$BUS 0x45 \$reg \$val >/dev/null 2>&1 || return
    probes=\$((probes+1))
    sleep 0.15
    t=\$(touch_state); c=\$(ctrl_state)
    if [ \"\$t\" != \"\$base_t\" ] || [ \"\$c\" != \"\$base_c\" ]; then
        hits=\$((hits+1))
        echo \"  *** EFFECT: reg=\$reg val=\$val\"
        [ \"\$t\" != \"\$base_t\" ] && echo \"        touch: \$base_t  ->  \$t\"
        [ \"\$c\" != \"\$base_c\" ] && echo \"        ctrl : \$base_c  ->  \$c\"
        base_t=\$t; base_c=\$c
    fi
}

echo '=== block 1: protocol A neighbourhood 0x80-0x8f ==='
for r in 0x80 0x81 0x82 0x83 0x84 0x85 0x86 0x87 0x88 0x89 0x8a 0x8b 0x8c 0x8d 0x8e 0x8f; do
    for v in 0x00 0x01 0x0f 0xff; do probe \$r \$v; done
done

echo '=== block 2: protocol B neighbourhood 0x90-0x9f ==='
for r in 0x90 0x91 0x92 0x93 0x94 0x95 0x96 0x97 0x98 0x99 0x9a 0x9b 0x9c 0x9d 0x9e 0x9f; do
    for v in 0x00 0x01 0xff; do probe \$r \$v; done
done

echo '=== block 3: protocol C neighbourhood 0xa8-0xaf and 0xc0-0xc7 ==='
for r in 0xa8 0xa9 0xaa 0xab 0xac 0xad 0xae 0xaf 0xc0 0xc1 0xc2 0xc3 0xc4 0xc5 0xc6 0xc7; do
    for v in 0x00 0x01 0xff; do probe \$r \$v; done
done

echo
echo \"probes attempted: \$probes   writes with a detectable effect: \$hits\"
if [ \$hits -eq 0 ]; then
    echo '  >>> no write to any of these registers changed anything observable'
fi
"

echo
echo "=== final state ==="
printf '  touch 0x38: %s\n' "$(S i2ctransfer -f -y "$B" w1@0x38 0x00 r8 2>&1)"
printf '  ctrl  0x45: 0x80=%s 0x82=%s 0x83=%s\n' \
  "$(S i2cget -f -y "$B" 0x45 0x80 2>&1)" \
  "$(S i2cget -f -y "$B" 0x45 0x82 2>&1)" \
  "$(S i2cget -f -y "$B" 0x45 0x83 2>&1)"

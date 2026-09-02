#!/bin/sh
# Runs ON the UNO Q. Stdin secrets contract: 1. sudo password  2. SSID  3. wifi pw
#
# Live touch readout using i2ctransfer, which performs the combined
# write-pointer + repeated-START + block read the FT5x06 requires.
# (My ctypes I2C_RDWR wrapper was malformed; i2ctransfer does it correctly.)
#
# FT5x06 map: 0x02 TD_STATUS (low nibble = contacts)
#             0x03 XH (bits7-6 event, bits3-0 X hi) 0x04 XL
#             0x05 YH (bits7-4 id,    bits3-0 Y hi) 0x06 YL
unset HISTFILE
IFS= read -r SUDO_PASS; SUDO_PASS=$(printf '%s' "$SUDO_PASS" | tr -d '\r')
IFS= read -r WIFI_SSID
IFS= read -r WIFI_PASS
S() { printf '%s\n' "$SUDO_PASS" | sudo -S -p '' "$@"; }
S true 2>/dev/null || { echo "SUDO PASSWORD REJECTED"; exit 1; }

B=$(basename "$(ls -d /sys/bus/i2c/devices/*-0045 2>/dev/null | head -1)" | cut -d- -f1)
echo "i2c bus = $B"

# let i2ctransfer run without a password prompt inside the tight loop
echo
echo "*** TOUCH AND DRAG ON THE PANEL FOR 25 SECONDS ***"
echo

S sh -c "
end=\$(( \$(date +%s) + 25 ))
last=''
n=0; hits=0
while [ \$(date +%s) -lt \$end ]; do
    out=\$(i2ctransfer -f -y $B w1@0x38 0x00 r7 2>/dev/null)
    n=\$((n+1))
    [ -z \"\$out\" ] && continue
    set -- \$out
    td=\$(( \$3 & 0x0f ))
    if [ \$td -ge 1 ] && [ \$td -le 5 ]; then
        xh=\$4; xl=\$5; yh=\$6; yl=\$7
        ev=\$(( xh >> 6 ))
        x=\$(( ((xh & 0x0f) << 8) | xl ))
        y=\$(( ((yh & 0x0f) << 8) | yl ))
        id=\$(( yh >> 4 ))
        if [ \$ev -ne 1 ]; then
            line=\"TOUCH n=\$td id=\$id x=\$x y=\$y ev=\$ev\"
            if [ \"\$line\" != \"\$last\" ]; then echo \"  \$line\"; last=\"\$line\"; fi
            hits=\$((hits+1))
        fi
    fi
done
echo
echo \"  polls: \$n   samples with a contact: \$hits\"
"

echo
echo "=== final raw read ==="
S i2ctransfer -f -y "$B" w1@0x38 0x00 r8 2>&1

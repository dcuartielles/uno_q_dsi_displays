#!/bin/sh
# Runs ON the UNO Q. Stdin secrets contract: 1. sudo password  2. SSID  3. wifi pw
#
# The digitiser produced exactly one valid report right after its reset was
# released, then froze with stale register values. So: cycle RST_TP_N and poll
# immediately, the way RPi's driver does (RESET_DELAY_MS 300, then poll at 60fps).
unset HISTFILE
IFS= read -r SUDO_PASS; SUDO_PASS=$(printf '%s' "$SUDO_PASS" | tr -d '\r')
IFS= read -r WIFI_SSID
IFS= read -r WIFI_PASS
S() { printf '%s\n' "$SUDO_PASS" | sudo -S -p '' "$@"; }
S true 2>/dev/null || { echo "SUDO PASSWORD REJECTED"; exit 1; }

B=$(basename "$(ls -d /sys/bus/i2c/devices/*-0045 2>/dev/null | head -1)" | cut -d- -f1)
echo "i2c bus = $B"
echo
echo "*** START TOUCHING AND DRAGGING NOW - keep going for ~30 seconds ***"
echo

S sh -c "
echo '  cycling RST_TP_N (PORTC 0x0d -> 0x0f)'
i2cset -f -y $B 0x45 0x83 0x0d 2>/dev/null; sleep 0.3
i2cset -f -y $B 0x45 0x83 0x0f 2>/dev/null; sleep 0.5

end=\$(( \$(date +%s) + 25 ))
last=''; n=0; hits=0; distinct=0; prev=''
while [ \$(date +%s) -lt \$end ]; do
    out=\$(i2ctransfer -f -y $B w1@0x38 0x00 r7 2>/dev/null)
    n=\$((n+1))
    [ -z \"\$out\" ] && continue
    set -- \$out
    td=\$(( \$3 & 0x0f ))
    raw=\"\$4 \$5 \$6 \$7\"
    if [ \"\$raw\" != \"\$prev\" ]; then distinct=\$((distinct+1)); prev=\"\$raw\"; fi
    if [ \$td -ge 1 ] && [ \$td -le 5 ]; then
        xh=\$4; xl=\$5; yh=\$6; yl=\$7
        ev=\$(( xh >> 6 ))
        x=\$(( ((xh & 0x0f) << 8) | xl ))
        y=\$(( ((yh & 0x0f) << 8) | yl ))
        id=\$(( yh >> 4 ))
        hits=\$((hits+1))
        line=\"TOUCH id=\$id x=\$x y=\$y ev=\$ev\"
        if [ \"\$line\" != \"\$last\" ]; then echo \"  \$line\"; last=\"\$line\"; fi
    fi
done
echo
echo \"  polls=\$n  contacts=\$hits  distinct-register-states=\$distinct\"
if [ \$distinct -le 1 ]; then
    echo '  >>> registers never changed - the digitiser is NOT scanning'
else
    echo '  >>> register contents changed - the digitiser IS scanning'
fi
"

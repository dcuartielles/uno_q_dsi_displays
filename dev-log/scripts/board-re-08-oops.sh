#!/bin/sh
# Runs ON the UNO Q. Stdin secrets contract: 1. sudo password  2. SSID  3. wifi pw
# chipone_atomic_pre_enable faulted. Get the full oops and the source around it.
unset HISTFILE
IFS= read -r SUDO_PASS; SUDO_PASS=$(printf '%s' "$SUDO_PASS" | tr -d '\r')
IFS= read -r WIFI_SSID
IFS= read -r WIFI_PASS
S() { printf '%s\n' "$SUDO_PASS" | sudo -S -p '' "$@"; }

echo "############ the full oops ############"
dmesg | grep -n -B8 -A45 'chipone_atomic_pre_enable' | head -90

echo
echo "############ what kind of fault? ############"
dmesg | grep -iE 'Unable to handle|Internal error|BUG:|Oops|pc :|lr :|Call trace|WARNING' | head -20

echo
echo "############ chipone_atomic_pre_enable source ############"
sed -n '/static void chipone_atomic_pre_enable/,/^}/p' "$HOME/panel-build/chipone-icn6211.c"

echo
echo "############ chipone_configure / what pre_enable calls ############"
sed -n '/static void chipone_configure(/,/^}/p' "$HOME/panel-build/chipone-icn6211.c" | head -40

echo
echo "############ chipone_dsi_attach + probe ############"
sed -n '/static int chipone_dsi_attach/,/^}/p' "$HOME/panel-build/chipone-icn6211.c"
sed -n '/static int chipone_dsi_probe/,/^}/p' "$HOME/panel-build/chipone-icn6211.c"

echo
echo "############ chipone_parse_dt - what it expects ############"
sed -n '/static int chipone_parse_dt/,/^}/p' "$HOME/panel-build/chipone-icn6211.c"

echo
echo "############ current display state ############"
for s in /sys/class/drm/*/status; do [ -f "$s" ] && echo "  $(basename "$(dirname "$s")") => $(cat "$s")"; done
for m in /sys/class/drm/*/modes; do [ -f "$m" ] && echo "  modes: $(tr '\n' ' ' < "$m")"; done
ls -la /dev/fb0 2>/dev/null || echo "  no /dev/fb0"
lsmod | grep -iE 'chipone|panel_simple|attiny'

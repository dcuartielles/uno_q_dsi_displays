#!/bin/sh
# Runs ON the UNO Q. Stdin secrets contract: 1. sudo password  2. SSID  3. wifi pw
# Extract RPi's polling implementation from edt-ft5x06.c so it can be backported
# into mainline, which requires a hardware IRQ we do not have.
unset HISTFILE
IFS= read -r SUDO_PASS; IFS= read -r WIFI_SSID; IFS= read -r WIFI_PASS

D="$HOME/driver-compare"; mkdir -p "$D"; cd "$D" || exit 1
RPI=https://raw.githubusercontent.com/raspberrypi/linux/rpi-6.12.y
MLN=https://raw.githubusercontent.com/arduino/linux-qcom/122c2c22d838
[ -s rpi/edt-ft5x06.c ] || { mkdir -p rpi; curl -fsSL --max-time 90 "$RPI/drivers/input/touchscreen/edt-ft5x06.c" -o rpi/edt-ft5x06.c 2>/dev/null; }
[ -s mainline/edt-ft5x06.c ] || { mkdir -p mainline; curl -fsSL --max-time 90 "$MLN/drivers/input/touchscreen/edt-ft5x06.c" -o mainline/edt-ft5x06.c 2>/dev/null; }
printf 'rpi=%s  mainline=%s lines\n' "$(wc -l < rpi/edt-ft5x06.c)" "$(wc -l < mainline/edt-ft5x06.c)"

echo
echo "############ RPi: polling defines ############"
grep -n 'POLL_INTERVAL_MS\|FIRST_POLL_DELAY_MS\|RESET_DELAY_MS' rpi/edt-ft5x06.c | head

echo
echo "############ RPi: struct fields for polling ############"
grep -n -B2 -A4 'struct timer_list timer\|work_i2c_poll' rpi/edt-ft5x06.c | head -20

echo
echo "############ RPi: the poll timer + work functions ############"
sed -n '/static void edt_ft5x06_ts_irq_poll_timer/,/^}/p' rpi/edt-ft5x06.c
sed -n '/static void edt_ft5x06_ts_work_i2c_poll/,/^}/p' rpi/edt-ft5x06.c

echo
echo "############ RPi: probe - how it chooses IRQ vs polling ############"
grep -n -B6 -A26 'irq_poll_timer\|timer_setup' rpi/edt-ft5x06.c | head -60

echo
echo "############ RPi: remove/teardown ############"
grep -n -B3 -A12 'del_timer\|timer_delete\|cancel_work' rpi/edt-ft5x06.c | head -30

echo
echo "############ MAINLINE: the probe section that fails for us ############"
grep -n -B8 -A16 'Unable to request touchscreen IRQ' mainline/edt-ft5x06.c

#!/bin/sh
# Runs ON the UNO Q. Stdin secrets contract: 1. sudo password  2. SSID  3. wifi pw
#
# Backport two RPi-downstream behaviours that mainline lacks:
#
#  A) tc358762: program the DPI output timing registers from ctx->mode.
#     Mainline has the mode and the mode_set callback but never writes
#     LCD_HS_HBP / LCD_HDISP_HFP / LCD_VS_VBP / LCD_VDISP_VFP, so the bridge
#     drives the panel with default timings.
#
#  B) attiny is_enabled: use the CACHED port state, as RPi does. Mainline reads
#     PORTC back from the chip, but on this panel PORTC always reads 0x10, so
#     is_enabled reports "disabled" even when the panel is powered.
#
#  (our earlier write-retry patch is re-applied too)
unset HISTFILE
IFS= read -r SUDO_PASS; SUDO_PASS=$(printf '%s' "$SUDO_PASS" | tr -d '\r')
IFS= read -r WIFI_SSID
IFS= read -r WIFI_PASS
S() { printf '%s\n' "$SUDO_PASS" | sudo -S -p '' "$@"; }
S true 2>/dev/null || { echo "SUDO PASSWORD REJECTED"; exit 1; }

cd "$HOME/panel-build" || exit 1
K=$(uname -r)

# fresh copies
[ -f tc358762.c.orig ] || cp tc358762.c tc358762.c.orig
cp tc358762.c.orig tc358762.c
cp rpi-panel-attiny-regulator.c.orig rpi-panel-attiny-regulator.c

python3 - <<'PY'
# ---------------- A) tc358762 timing registers ----------------
p = 'tc358762.c'
s = open(p).read()

anchor = '#define LCDCTRL_VSDELAY(v)\t(((v) & 0xfff) << 20) /* VSYNC delay */'
assert anchor in s, "LCDCTRL_VSDELAY anchor missing"
s = s.replace(anchor, anchor + """

/* DPI output timing. Present in RPi downstream, absent from mainline.
 * First parameter is in the low 16 bits, second in the top 16 bits.
 */
#define LCD_HS_HBP\t\t0x0424
#define LCD_HDISP_HFP\t\t0x0428
#define LCD_VS_VBP\t\t0x042c
#define LCD_VDISP_VFP\t\t0x0430""", 1)

old = """\ttc358762_write(ctx, SYSCTRL, 0x040f);
\tmsleep(100);"""
new = """\ttc358762_write(ctx, SYSCTRL, 0x040f);

\t/* Program the DPI output timing from the mode - mainline omits this. */
\ttc358762_write(ctx, LCD_HS_HBP, (ctx->mode.hsync_end - ctx->mode.hsync_start) |
\t\t       ((ctx->mode.htotal - ctx->mode.hsync_end) << 16));
\ttc358762_write(ctx, LCD_HDISP_HFP, ctx->mode.hdisplay |
\t\t       ((ctx->mode.hsync_start - ctx->mode.hdisplay) << 16));
\ttc358762_write(ctx, LCD_VS_VBP, (ctx->mode.vsync_end - ctx->mode.vsync_start) |
\t\t       ((ctx->mode.vtotal - ctx->mode.vsync_end) << 16));
\ttc358762_write(ctx, LCD_VDISP_VFP, ctx->mode.vdisplay |
\t\t       ((ctx->mode.vsync_start - ctx->mode.vdisplay) << 16));
\tpr_info("tc358762-dbg: init mode %ux%u clk=%d hs=%u-%u ht=%u vs=%u-%u vt=%u flags=0x%x\\n",
\t\tctx->mode.hdisplay, ctx->mode.vdisplay, ctx->mode.clock,
\t\tctx->mode.hsync_start, ctx->mode.hsync_end, ctx->mode.htotal,
\t\tctx->mode.vsync_start, ctx->mode.vsync_end, ctx->mode.vtotal,
\t\tctx->mode.flags);
\tmsleep(100);"""
assert old in s, "SYSCTRL anchor missing"
s = s.replace(old, new, 1)
open(p, 'w').write(s)
print("A) tc358762 patched: timing registers + debug print")

# ---------------- B) attiny: retries + cached is_enabled ----------------
p = 'rpi-panel-attiny-regulator.c'
s = open(p).read()

old = """\tstate->port_states[reg - REG_PORTA] = val;
\treturn regmap_write(state->regmap, reg, val);"""
new = """\tint dbg_ret, dbg_i;

\tstate->port_states[reg - REG_PORTA] = val;

\tfor (dbg_i = 0; dbg_i < 60; dbg_i++) {
\t\tdbg_ret = regmap_write(state->regmap, reg, val);
\t\tif (!dbg_ret)
\t\t\tbreak;
\t\tmsleep(50);
\t}
\tpr_info("attiny-dbg: WRITE reg=0x%02x val=0x%02x ret=%d attempts=%d\\n",
\t\treg, val, dbg_ret, dbg_i + 1);
\treturn dbg_ret;"""
assert old in s
s = s.replace(old, new, 1)

old = """\tscoped_guard(mutex, &state->lock) {
\t\tfor (i = 0; i < 10; i++) {
\t\t\tret = regmap_read(rdev->regmap, REG_PORTC, &data);
\t\t\tif (!ret)
\t\t\t\tbreak;
\t\t\tusleep_range(10000, 12000);
\t\t}
\t}

\tif (ret < 0)
\t\treturn ret;

\treturn data & PC_RST_BRIDGE_N;"""
new = """\t/* RPi downstream uses the CACHED port state here. Mainline reads PORTC
\t * back from the chip, but this panel always returns 0x10 regardless of
\t * what was written, so the hardware read reports "disabled" even when
\t * the panel is powered. Trust the cache, as RPi does.
\t */
\t(void)data; (void)ret; (void)i;
\tguard(mutex)(&state->lock);
\tdata = state->port_states[REG_PORTC - REG_PORTA];
\tpr_info("attiny-dbg: is_enabled cached PORTC=0x%02x -> %d\\n",
\t\tdata, !!(data & PC_RST_BRIDGE_N));
\treturn data & PC_RST_BRIDGE_N;"""
assert old in s
s = s.replace(old, new, 1)

old = """\tfor (i = 0; i < 10; i++) {
\t\tret = regmap_write(regmap, REG_PWM, brightness);
\t\tif (!ret)
\t\t\tbreak;
\t}

\treturn ret;"""
new = """\tfor (i = 0; i < 60; i++) {
\t\tret = regmap_write(regmap, REG_PWM, brightness);
\t\tif (!ret)
\t\t\tbreak;
\t\tmsleep(50);
\t}
\tpr_info("attiny-dbg: BACKLIGHT brightness=%d ret=%d attempts=%d\\n",
\t\tbrightness, ret, i + 1);
\treturn ret;"""
assert old in s
s = s.replace(old, new, 1)
open(p, 'w').write(s)
print("B) attiny patched: write retries + cached is_enabled")
PY

echo
echo "=== rebuild both modules ==="
make -C "/lib/modules/$K/build" M="$PWD" modules 2>&1 | tail -8
ls -la tc358762.ko rpi-panel-attiny-regulator.ko

echo
echo "=== install ==="
S cp tc358762.ko rpi-panel-attiny-regulator.ko "/lib/modules/$K/extra/"
S depmod -a

echo
echo "=== rebooting in 3s ==="
S nohup sh -c 'sleep 3; systemctl reboot' >/dev/null 2>&1 &
sleep 1
echo "reboot scheduled"

#!/bin/sh
# Runs ON the UNO Q. Stdin secrets contract: 1. sudo password  2. SSID  3. wifi pw
#
# The remaining behavioural difference from RPi downstream:
#
#   RPi      : tc358762_pre_enable()  -> regulator, reset, tc358762_init()
#   mainline : tc358762_pre_enable()  -> regulator, reset
#              tc358762_enable()      -> tc358762_init()
#
# pre_enable runs BEFORE the video stream starts; atomic_enable runs after.
# The bridge's setup registers are DSI low-power command writes, so issuing
# them while the host is already streaming video is a plausible cause of the
# persistent dsi_err_worker status=4 (data lane 0 PHY error).
#
# Move init back to pre_enable, as RPi does.
unset HISTFILE
IFS= read -r SUDO_PASS; SUDO_PASS=$(printf '%s' "$SUDO_PASS" | tr -d '\r')
IFS= read -r WIFI_SSID
IFS= read -r WIFI_PASS
S() { printf '%s\n' "$SUDO_PASS" | sudo -S -p '' "$@"; }
S true 2>/dev/null || { echo "SUDO PASSWORD REJECTED"; exit 1; }

cd "$HOME/panel-build" || exit 1
K=$(uname -r)

python3 - <<'PY'
p = 'tc358762.c'
s = open(p).read()

# 1. call init from pre_enable, as RPi does
old = """\tctx->pre_enabled = true;
}"""
new = """\tctx->pre_enabled = true;

\t/* RPi downstream initialises the bridge HERE, in pre_enable, before the
\t * video stream starts. Mainline moved it to atomic_enable, which issues
\t * the DSI LP command writes after the host is already streaming.
\t */
\tret = tc358762_init(ctx);
\tif (ret < 0)
\t\tdev_err(ctx->dev, "error initializing bridge in pre_enable (%d)\\n", ret);
\tpr_info("tc358762-dbg: init from PRE_ENABLE ret=%d\\n", ret);
}"""
assert old in s, "pre_enable anchor missing"
assert s.count(old) == 1, "pre_enable anchor not unique"
s = s.replace(old, new, 1)

# 2. stop calling it again from atomic_enable
old = "\t.atomic_enable = tc358762_enable,\n"
assert old in s, "atomic_enable funcs entry missing"
s = s.replace(old, "", 1)

# 3. keep the now-unused function compiling
old = "static void tc358762_enable(struct drm_bridge *bridge,"
assert old in s
s = s.replace(old, "static void __maybe_unused tc358762_enable(struct drm_bridge *bridge,", 1)

open(p, 'w').write(s)
print("patched: tc358762_init() now runs from pre_enable")
PY

echo
echo "=== verify the patch ==="
grep -n -A6 "pre_enabled = true" tc358762.c | head -14
echo "--- funcs (atomic_enable should be gone) ---"
grep -n -A10 "tc358762_bridge_funcs = {" tc358762.c

echo
echo "=== rebuild ==="
make -C "/lib/modules/$K/build" M="$PWD" modules 2>&1 | tail -6
ls -la tc358762.ko

echo
echo "=== install ==="
S cp tc358762.ko "/lib/modules/$K/extra/"
S depmod -a

echo
echo "=== rebooting in 3s ==="
S nohup sh -c 'sleep 3; systemctl reboot' >/dev/null 2>&1 &
sleep 1
echo "reboot scheduled"

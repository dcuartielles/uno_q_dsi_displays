#!/bin/sh
# Run a command on the board as root, from the benchmark host.
#
#   bench/remote.sh 'cat /sys/class/backlight/*/brightness'
#
# Configure with environment variables, or a bench/bench.conf next to this
# script (which is gitignored - do not commit credentials):
#
#   UNOQ_HOST=192.168.1.50        # board address, required
#   UNOQ_USER=arduino             # login user
#   UNOQ_SSH_KEY=~/.ssh/unoq      # key for passwordless login
#   UNOQ_SUDO_PASS=...            # only if sudo needs a password
#
# The nicest setup is passwordless sudo on the board, which removes the need
# to keep a password on the benchmark host at all:
#
#   echo 'arduino ALL=(ALL) NOPASSWD: ALL' | sudo tee /etc/sudoers.d/bench
set -eu
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)

# shellcheck disable=SC1091
[ -f "$HERE/bench.conf" ] && . "$HERE/bench.conf"

: "${UNOQ_HOST:?set UNOQ_HOST (see comments in bench/remote.sh)}"
: "${UNOQ_USER:=arduino}"
: "${UNOQ_SUDO_PASS:=}"

[ $# -ge 1 ] || { echo "usage: $0 <command...>" >&2; exit 2; }

SSH_OPTS="-o StrictHostKeyChecking=no -o BatchMode=yes -o ConnectTimeout=8"
[ -n "${UNOQ_KNOWN_HOSTS:-}" ] && SSH_OPTS="$SSH_OPTS -o UserKnownHostsFile=$UNOQ_KNOWN_HOSTS"
[ -n "${UNOQ_SSH_KEY:-}" ] && SSH_OPTS="$SSH_OPTS -i $UNOQ_SSH_KEY"

# -S reads the sudo password from stdin; with NOPASSWD the empty line is
# harmless and sudo never asks.
# shellcheck disable=SC2086
printf '%s\n' "$UNOQ_SUDO_PASS" | \
    ssh $SSH_OPTS "$UNOQ_USER@$UNOQ_HOST" "sudo -S -p '' sh -c $(
        # single-quote the whole remote command safely
        printf "%s" "$*" | sed "s/'/'\\\\''/g; s/^/'/; s/\$/'/"
    )"

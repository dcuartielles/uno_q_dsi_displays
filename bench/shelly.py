#!/usr/bin/env python3
"""Drive a Shelly smart plug, so cold-boot runs need nobody at the socket.

The benchmark's manual mode asks a human to pull the plug for every iteration.
That is what kept N small: the cold-boot bug needs dozens of boots to measure
and nobody wants to sit there for a hundred power cycles. A smart plug removes
the human and nothing else changes.

    python bench/shelly.py status        # is it reachable, and is it on?
    python bench/shelly.py on
    python bench/shelly.py off
    python bench/shelly.py cycle         # off, wait, on - what the bench does
    python bench/shelly.py selftest      # prove it works BEFORE a long run

Configure in bench/bench.conf (gitignored, next to this file):

    SHELLY_HOST=192.168.1.50
    SHELLY_CHANNEL=0
    SHELLY_AUTH=user:password      # only if you set a password on the device

Both API generations are handled, and which one you have is detected rather
than configured:

    Gen1  (Shelly Plug S, Shelly 1PM)     /relay/0?turn=on
    Gen2+ (Plus/Pro/Mini, Gen3, Gen4)     /rpc/Switch.Set?id=0&on=true

Everything is local HTTP. No cloud account, and it keeps working when the
internet does not - which matters, because a run that dies halfway through
loses every boot the operator already paid for.

If the device has a password set, Gen2+ answers with digest authentication
(SHA-256, per RFC 7616) rather than the basic scheme, and the username is
always "admin" regardless of what the app shows. Both are handled; put the
password in SHELLY_AUTH and it is sent only in response to a challenge, never
speculatively.
"""
import hashlib
import json
import os
import random
import sys
import time
import urllib.error
import urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))

# Cutting power to a board is not free: a write in flight can corrupt the
# filesystem. The benchmark syncs before calling this, but the pause below is
# the other half - it lets the rails actually discharge, so the next boot is a
# genuine cold start rather than a warm one wearing a disguise.
DEFAULT_OFF_SECONDS = 8

# Short, because every request here is on the LAN. A plug that has gone away
# should be reported quickly rather than stalling a hundred-iteration run.
TIMEOUT = 6


class ShellyError(Exception):
    pass


def load_conf():
    """Read bench.conf, the same file the benchmark itself uses."""
    conf = {}
    path = os.path.join(HERE, "bench.conf")
    try:
        with open(path) as fh:
            for line in fh:
                line = line.strip()
                if not line or line.startswith("#") or "=" not in line:
                    continue
                k, v = line.split("=", 1)
                conf[k.strip()] = v.strip().strip('"').strip("'")
    except IOError:
        pass
    return conf


class Shelly(object):
    def __init__(self, host, channel=0, auth=None):
        if not host:
            raise ShellyError(
                "no Shelly host. Put SHELLY_HOST=<ip> in bench/bench.conf, or "
                "pass --host. The address is in the Shelly app under the "
                "device's settings, or on its web page.")
        self.host = host.replace("http://", "").replace("https://", "").rstrip("/")
        self.channel = int(channel)
        self.auth = auth
        self._gen = None

    # ------------------------------------------------------------- plumbing --
    @staticmethod
    def _parse_challenge(header):
        """Pull the fields out of a WWW-Authenticate line."""
        fields = {}
        rest = header.split(None, 1)[1] if " " in header else header
        for part in rest.split(","):
            if "=" not in part:
                continue
            k, v = part.split("=", 1)
            fields[k.strip().lower()] = v.strip().strip('"')
        return fields

    def _digest_header(self, challenge, method, uri):
        """Build an RFC 7616 digest response.

        Shelly Gen2+ challenges with SHA-256. urllib's own digest handler
        speaks MD5 and SHA-1 only, so this is done by hand rather than fought
        with - it is a dozen lines and it fails loudly instead of silently
        downgrading.
        """
        algo = challenge.get("algorithm", "MD5").upper()
        if algo.startswith("SHA-256") or algo.startswith("SHA256"):
            h = lambda s: hashlib.sha256(s.encode()).hexdigest()
        elif algo.startswith("MD5"):
            h = lambda s: hashlib.md5(s.encode()).hexdigest()
        else:
            raise ShellyError(
                "%s asked for digest algorithm %s, which is not supported"
                % (self.host, algo))

        user, _, password = self.auth.partition(":")
        if not password:
            # Gen2+ has a single fixed account. Accepting a bare password and
            # filling this in is one less thing to get wrong.
            user, password = "admin", user

        realm = challenge.get("realm", "")
        nonce = challenge.get("nonce", "")
        qop = challenge.get("qop", "auth").split(",")[0].strip()
        nc = "00000001"
        cnonce = "%08x" % random.getrandbits(32)

        ha1 = h("%s:%s:%s" % (user, realm, password))
        ha2 = h("%s:%s" % (method, uri))
        if qop:
            resp = h("%s:%s:%s:%s:%s:%s" % (ha1, nonce, nc, cnonce, qop, ha2))
        else:
            resp = h("%s:%s:%s" % (ha1, nonce, ha2))

        parts = ['username="%s"' % user, 'realm="%s"' % realm,
                 'nonce="%s"' % nonce, 'uri="%s"' % uri,
                 'response="%s"' % resp, "algorithm=%s" % algo]
        if qop:
            parts += ["qop=%s" % qop, "nc=%s" % nc, 'cnonce="%s"' % cnonce]
        if "opaque" in challenge:
            parts.append('opaque="%s"' % challenge["opaque"])
        return "Digest " + ", ".join(parts)

    def _open(self, uri, auth_header=None):
        req = urllib.request.Request("http://%s%s" % (self.host, uri))
        if auth_header:
            req.add_header("Authorization", auth_header)
        with urllib.request.urlopen(req, timeout=TIMEOUT) as resp:
            return resp.read().decode("utf-8", "replace")

    def _get(self, path):
        url = "http://%s%s" % (self.host, path)
        try:
            body = self._open(path)
        except urllib.error.HTTPError as e:
            if e.code != 401:
                raise ShellyError("%s returned HTTP %s" % (url, e.code))
            # Answer the challenge. The password is only ever sent in reply to
            # one, so a device with authentication turned off never sees it.
            if not self.auth:
                raise ShellyError(
                    "%s has a password set. Add SHELLY_AUTH=<password> to "
                    "bench/bench.conf (the username on Gen2+ is always "
                    "'admin', so the password alone is enough)." % self.host)
            challenge = self._parse_challenge(e.headers.get("WWW-Authenticate", ""))
            try:
                body = self._open(path, self._digest_header(challenge, "GET", path))
            except urllib.error.HTTPError as e2:
                if e2.code == 401:
                    raise ShellyError(
                        "%s rejected the password in SHELLY_AUTH." % self.host)
                raise ShellyError("%s returned HTTP %s" % (url, e2.code))
        except Exception as e:
            raise ShellyError("cannot reach %s (%s)" % (url, e))
        try:
            return json.loads(body)
        except ValueError:
            return {"raw": body}

    def gen(self):
        """1 for the original API, 2 for the RPC one. Asked, not assumed."""
        if self._gen is None:
            info = self._get("/shelly")
            # Gen2+ report "gen"; Gen1 has no such field.
            self._gen = int(info.get("gen", 1))
        return self._gen

    def describe(self):
        info = self._get("/shelly")
        name = info.get("model") or info.get("type") or info.get("app") or "?"
        return "%s (gen %s) at %s" % (name, self.gen(), self.host)

    # ---------------------------------------------------------------- state --
    def is_on(self):
        if self.gen() >= 2:
            r = self._get("/rpc/Switch.GetStatus?id=%d" % self.channel)
            if "output" not in r:
                raise ShellyError(
                    "no switch %d on this device - set SHELLY_CHANNEL to a "
                    "channel it has" % self.channel)
            return bool(r["output"])
        r = self._get("/relay/%d" % self.channel)
        if "ison" not in r:
            raise ShellyError("no relay %d on this device" % self.channel)
        return bool(r["ison"])

    def set(self, on, verify=True):
        """Switch, then read back. An HTTP 200 is not proof the relay moved."""
        if self.gen() >= 2:
            self._get("/rpc/Switch.Set?id=%d&on=%s"
                      % (self.channel, "true" if on else "false"))
        else:
            self._get("/relay/%d?turn=%s" % (self.channel, "on" if on else "off"))
        if not verify:
            return True
        for _ in range(10):
            time.sleep(0.4)
            try:
                if self.is_on() == on:
                    return True
            except ShellyError:
                pass
        raise ShellyError(
            "asked the plug to turn %s and it did not report doing so. Check "
            "SHELLY_CHANNEL, and that nothing else is driving this plug."
            % ("on" if on else "off"))

    def cycle(self, off_seconds=DEFAULT_OFF_SECONDS):
        self.set(False)
        time.sleep(off_seconds)
        self.set(True)


def from_conf(args_host=None, args_channel=None):
    conf = load_conf()
    host = args_host or os.environ.get("SHELLY_HOST") or conf.get("SHELLY_HOST")
    channel = args_channel
    if channel is None:
        channel = os.environ.get("SHELLY_CHANNEL") or conf.get("SHELLY_CHANNEL") or 0
    auth = os.environ.get("SHELLY_AUTH") or conf.get("SHELLY_AUTH")
    return Shelly(host, channel, auth)


def selftest(plug, off_seconds):
    """Prove the plug works before betting a long run on it.

    Worth the minute it takes. A hundred-iteration run that discovers on
    iteration 1 that the channel number is wrong has wasted an evening, and the
    failure looks like a dead board rather than a mis-set plug.
    """
    print("device    : %s" % plug.describe())
    was_on = plug.is_on()
    print("state     : %s" % ("on" if was_on else "off"))

    print("turning off...")
    plug.set(False)
    print("  reads back: off")
    time.sleep(min(off_seconds, 3))

    print("turning on...")
    plug.set(True)
    print("  reads back: on")

    if not was_on:
        print("note: the plug was OFF when this started and is now ON.")
    print("\nselftest passed - this plug can drive an unattended cold-boot run.")
    return 0


def main(argv):
    import argparse
    p = argparse.ArgumentParser(
        description="Drive a Shelly smart plug for unattended cold boots.")
    p.add_argument("action",
                   choices=["status", "on", "off", "cycle", "selftest"])
    p.add_argument("--host", help="IP or hostname (default: SHELLY_HOST)")
    p.add_argument("--channel", type=int, help="switch/relay id (default 0)")
    p.add_argument("--off-seconds", type=float, default=DEFAULT_OFF_SECONDS,
                   help="how long to stay off in cycle (default %d)"
                        % DEFAULT_OFF_SECONDS)
    a = p.parse_args(argv)

    try:
        plug = from_conf(a.host, a.channel)
        if a.action == "status":
            print("%s: %s" % (plug.describe(), "on" if plug.is_on() else "off"))
        elif a.action == "on":
            plug.set(True); print("on")
        elif a.action == "off":
            plug.set(False); print("off")
        elif a.action == "cycle":
            plug.cycle(a.off_seconds); print("cycled")
        elif a.action == "selftest":
            return selftest(plug, a.off_seconds)
    except ShellyError as e:
        sys.stderr.write("ERROR: %s\n" % e)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))

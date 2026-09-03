#!/usr/bin/env python3
"""A tiny HTTP/CONNECT proxy so a USB-attached board can use the host's network.

Why
---
An UNO Q with no usable Wi-Fi cannot run apt, and on a guest network behind a
captive portal it never will without someone clicking through a login page.
But the board is already attached over USB, and the host is already on the
network. `adb reverse tcp:3128 tcp:3128` makes the host's port 3128 appear as
127.0.0.1:3128 *on the board*, so pointing apt at it borrows the host's
connection - no Wi-Fi, no portal, no network changes, and nothing to
authenticate.

This is not a way around the portal's authentication: the traffic is the
host's own already-authenticated connection, exactly as if you had downloaded
the packages on the host and copied them across.

Handles both what apt needs:
  * absolute-URI GET/HEAD   for http://deb.debian.org
  * CONNECT tunnels         for https://apt-repo.arduino.cc

Usage
-----
    python tools/usb-proxy.py                # host side, foreground
    adb reverse tcp:3128 tcp:3128            # device :3128 -> host :3128

then on the board:

    Acquire::http::Proxy  "http://127.0.0.1:3128";
    Acquire::https::Proxy "http://127.0.0.1:3128";
"""
import argparse
import select
import socket
import sys
import threading

BUF = 65536


def pipe(a, b):
    """Shovel bytes both ways until either side closes."""
    socks = [a, b]
    try:
        while True:
            r, _, x = select.select(socks, [], socks, 30)
            if x or not r:
                break
            for s in r:
                data = s.recv(BUF)
                if not data:
                    return
                (b if s is a else a).sendall(data)
    except OSError:
        pass
    finally:
        for s in socks:
            try:
                s.close()
            except OSError:
                pass


def read_headers(sock):
    """Read up to the end of the request headers."""
    data = b""
    while b"\r\n\r\n" not in data:
        chunk = sock.recv(BUF)
        if not chunk:
            break
        data += chunk
        if len(data) > 128 * 1024:
            break
    return data


def handle(client, verbose):
    try:
        head = read_headers(client)
        if not head:
            client.close()
            return
        first = head.split(b"\r\n", 1)[0].decode("latin-1")
        parts = first.split()
        if len(parts) < 3:
            client.close()
            return
        method, target = parts[0], parts[1]

        if method.upper() == "CONNECT":
            host, _, port = target.partition(":")
            port = int(port or 443)
            upstream = socket.create_connection((host, port), timeout=30)
            client.sendall(b"HTTP/1.1 200 Connection established\r\n\r\n")
            if verbose:
                print("  CONNECT %s:%d" % (host, port), flush=True)
            pipe(client, upstream)
            return

        # Absolute-URI request: http://host[:port]/path
        if not target.lower().startswith("http://"):
            client.sendall(b"HTTP/1.1 400 Bad Request\r\n\r\n")
            client.close()
            return
        rest = target[len("http://"):]
        hostport, _, path = rest.partition("/")
        host, _, port = hostport.partition(":")
        port = int(port or 80)
        path = "/" + path

        # Rewrite the request line to origin form for the upstream server.
        head = head.replace(first.encode("latin-1"),
                            ("%s %s %s" % (method, path, parts[2])).encode("latin-1"),
                            1)
        upstream = socket.create_connection((host, port), timeout=30)
        upstream.sendall(head)
        if verbose:
            print("  %s http://%s%s" % (method, hostport, path), flush=True)
        pipe(client, upstream)
    except Exception as exc:            # noqa: BLE001 - a proxy must not die
        if verbose:
            print("  error: %s" % exc, flush=True)
        try:
            client.close()
        except OSError:
            pass


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--port", type=int, default=3128)
    ap.add_argument("--bind", default="127.0.0.1")
    ap.add_argument("-v", "--verbose", action="store_true")
    args = ap.parse_args()

    srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    srv.bind((args.bind, args.port))
    srv.listen(128)
    print("proxy listening on %s:%d" % (args.bind, args.port), flush=True)
    print("run:  adb reverse tcp:%d tcp:%d" % (args.port, args.port), flush=True)

    try:
        while True:
            client, _ = srv.accept()
            threading.Thread(target=handle, args=(client, args.verbose),
                             daemon=True).start()
    except KeyboardInterrupt:
        print("stopping", flush=True)
    finally:
        srv.close()


if __name__ == "__main__":
    sys.exit(main())

#!/usr/bin/env python3
"""Containux display multiplexer: one VNC window that behaves like the
appliance's physical monitor.

The appliance test runs two VNC servers: the outer QEMU's console (the
first-boot TUI) and the inner guest's display (Windows). This mux serves
a single endpoint to the user and simulates a monitor attached to real
hardware:

  * while the appliance is configuring/booting, it mirrors the appliance
    console (outer QEMU VNC);
  * the moment the guest machine's VNC server appears, it switches the
    stream to the guest display and announces the new screen geometry
    with the RFB DesktopSize pseudo-encoding — a well-behaved viewer
    simply resizes its window in place;
  * when the guest powers off (and the appliance powers down with it),
    the connection closes, like a monitor losing signal.

Usage: vncmux.py LISTEN_PORT CONSOLE_HOST CONSOLE_PORT GUEST_HOST GUEST_PORT
"""

import select
import socket
import struct
import sys
import time

LISTEN = int(sys.argv[1]) if len(sys.argv) > 1 else 5901
CONSOLE = (sys.argv[2], int(sys.argv[3])) if len(sys.argv) > 2 else ("127.0.0.1", 5903)
GUEST = (sys.argv[4], int(sys.argv[5])) if len(sys.argv) > 4 else ("127.0.0.1", 5904)

POLL_INTERVAL = 2.0

# Global state shared across client connections: once the guest display
# has taken over the "monitor", reconnecting clients land directly on it.
switched = False
cached_format = None      # client's SetPixelFormat message (raw bytes)
cached_encodings = None   # client's SetEncodings message (raw bytes)


def log(msg):
    print("vncmux: %s" % msg, flush=True)


def recv_exact(s, n):
    buf = b""
    while len(buf) < n:
        chunk = s.recv(n - len(buf))
        if not chunk:
            raise EOFError("connection closed")
        buf += chunk
    return buf


def handshake_upstream(s):
    """Complete the RFB client-side handshake against an upstream VNC
    server. Returns (width, height)."""
    greeting = recv_exact(s, 12)
    if not greeting.startswith(b"RFB"):
        raise EOFError("not an RFB server")
    s.sendall(b"RFB 003.008\n")
    ntypes = recv_exact(s, 1)[0]
    if ntypes:
        types = recv_exact(s, ntypes)
        if 1 not in types:
            raise EOFError("upstream requires authentication")
        s.sendall(bytes([1]))
        if struct.unpack(">I", recv_exact(s, 4))[0] != 0:
            raise EOFError("upstream authentication failed")
    else:
        # RFB 3.3: the server dictates the security type
        if struct.unpack(">I", recv_exact(s, 4))[0] != 1:
            raise EOFError("upstream requires authentication")
    s.sendall(b"\x01")  # ClientInit: shared
    w, h = struct.unpack(">HH", recv_exact(s, 4))
    recv_exact(s, 16)   # server pixel format
    name_len = struct.unpack(">I", recv_exact(s, 4))[0]
    recv_exact(s, name_len)
    return w, h


def guest_display_ready():
    """The forwarded guest port accepts connections even while the guest
    is down (the forwarder only then fails) — only a real RFB greeting
    proves that the guest display is actually serving."""
    try:
        s = socket.create_connection(GUEST, 3)
    except OSError:
        return False
    try:
        s.settimeout(3)
        try:
            head = s.recv(12)
        except (socket.timeout, OSError):
            return False
        return head.startswith(b"RFB")
    finally:
        try:
            s.close()
        except OSError:
            pass


def split_client_messages(buf):
    """Split buffered client->server data into complete messages, so the
    pixel format and encodings can be cached for replay when switching
    upstreams. Returns (messages, remainder, desynced): on an unknown
    message type we stop parsing and relay the rest verbatim."""
    msgs = []
    pos = 0
    while pos < len(buf):
        t = buf[pos]
        if t == 0:
            n = 20
        elif t == 2:
            if pos + 4 > len(buf):
                break
            n = 4 + 4 * struct.unpack_from(">H", buf, pos + 2)[0]
        elif t == 3:
            n = 10
        elif t == 4:
            n = 8
        elif t == 5:
            n = 6
        elif t == 6:
            if pos + 8 > len(buf):
                break
            n = 8 + struct.unpack_from(">I", buf, pos + 4)[0]
        else:
            # QEMU/extension message we do not know: relay the rest raw
            msgs.append((t, buf[pos:]))
            return msgs, b"", True
        if pos + n > len(buf):
            break
        msgs.append((t, buf[pos:pos + n]))
        pos += n
    return msgs, buf[pos:], False


def connect_upstream(target, wait_seconds):
    """Connect to an upstream VNC server, retrying while it comes up."""
    deadline = time.time() + wait_seconds
    while True:
        try:
            return socket.create_connection(target, 5)
        except OSError:
            if time.time() > deadline:
                raise
            time.sleep(0.5)


def serve_client(client):
    global switched, cached_format, cached_encodings

    # Once the guest has taken over the "monitor", reconnecting clients
    # are bridged straight to the guest display.
    sw = switched
    upstream = connect_upstream(GUEST if sw else CONSOLE, 60)

    pending = b""       # undelivered tail of the client stream
    desynced = False    # gave up parsing client messages (relay raw)
    last_poll = 0.0

    while True:
        timeout = None if sw else POLL_INTERVAL
        r, _, _ = select.select([client, upstream], [], [], timeout)

        if client in r:
            data = client.recv(65536)
            if not data:
                return
            if sw or desynced:
                upstream.sendall(data)
            else:
                # relay message-by-message so the client's negotiated
                # pixel format and encodings can be cached for replay
                pending += data
                msgs, pending, desynced = split_client_messages(pending)
                for t, m in msgs:
                    if t == 0:
                        cached_format = m
                    elif t == 2:
                        cached_encodings = m
                    upstream.sendall(m)
                if desynced:
                    upstream.sendall(pending)
                    pending = b""

        if upstream in r:
            data = upstream.recv(65536)
            if not data:
                return
            client.sendall(data)

        # The main loop detects the guest display server-side; hand this
        # live viewer over as soon as that happens.
        if not sw and switched:
            old = upstream
            upstream = hand_over(client)
            sw = True
            try:
                old.close()
            except OSError:
                pass


def hand_over(client):
    """Hand the "monitor" to the guest: complete the guest handshake
    (invisible to the client), replay the client's pixel format and
    encodings, and announce the new geometry with a DesktopSize update
    so the viewer resizes its window in place."""
    global cached_format, cached_encodings
    guest = connect_upstream(GUEST, 10)
    w, h = handshake_upstream(guest)
    if cached_format:
        guest.sendall(cached_format)
    if cached_encodings:
        guest.sendall(cached_encodings)
    client.sendall(struct.pack(">BBH", 0, 0, 1) +
                   struct.pack(">HHHHi", 0, 0, w, h, -223))
    # pull a full frame even if the client does not re-ask
    guest.sendall(struct.pack(">BBHHHH", 3, 0, 0, 0, w, h))
    log("guest display took over the monitor (%dx%d)" % (w, h))
    return guest


def main():
    global switched
    srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    srv.bind(("0.0.0.0", LISTEN))
    srv.listen(4)
    # Accept with a timeout: idle cycles become guest-display polls.
    srv.settimeout(POLL_INTERVAL)
    log("listening on :%d — console %s:%d, guest %s:%d"
        % (LISTEN, CONSOLE[0], CONSOLE[1], GUEST[0], GUEST[1]))
    while True:
        # Detect the guest display server-side, independent of any
        # connected viewer, so the monitor state survives reconnects.
        try:
            client, addr = srv.accept()
        except socket.timeout:
            if not switched and guest_display_ready():
                switched = True
                log("guest display is up")
            continue
        log("client %s:%d connected" % addr)
        try:
            serve_client(client)
        except (EOFError, OSError) as e:
            log("client %s:%d left (%s)" % (addr[0], addr[1], e))
        finally:
            try:
                client.close()
            except OSError:
                pass


if __name__ == "__main__":
    main()

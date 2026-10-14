#!/usr/bin/env python3
"""gw-client-289.py — the #289 gateway suites' mTLS test client. Runs INSIDE an OTS container (python3 + ssl):
  docker exec -i -e TARGET=172.20.0.10 -e ACTION=<a> -e UID=<uid> -e CS=<callsign> -e CERT=/tmp/<u>.pem -e KEY=/tmp/<u>.key \
      [-e N= -e HOLD= -e DELAY= -e EXPECT= -e PORT=8089 -e CA=/app/ots/ca/ca.pem] ots_cot_parser python3 - < this
ACTION:
  hold      identify (SA), hold HOLD s reading, print "KEPT <uid> <s>" or "CLOSED <uid> after <s>"; prints "PORT <n>" first
  noread    identify, then NEVER read and send nothing for HOLD s (a phone whose radio died: the server's writes
            pile up in our receive buffer; the socket stays open) -> "PORT <n>", then "NOREAD <uid> done"
  stream    identify, send N contact-less events (uid <uid>-p<i>) DELAY s apart, hold HOLD s -> "SENT <n>"
  readcount identify, read for HOLD s, count distinct uids matching EXPECT (a uid prefix) -> "GOT <n>"
  pingflood identify? no: send N pings as fast as possible without reading, report whether the socket stayed
            open and how long the writes took -> "PINGS <n> <seconds> open=<0|1>"
  oversize  identify, send one event with a <remarks> of SIZE bytes, then a ping; print "PONG <0|1>" (session kept?)
  rawflood  open N plain TCP sockets to TARGET:PORT, never start TLS, hold HOLD s, count how many are still
            open at the end -> "RAW <n> open=<k>"
  refused   identify and read: print "CLOSED <uid> after <s>" / "KEPT ..." (used for the refusal legs)
"""
import datetime
import os
import socket
import ssl
import sys
import threading
import time

T = os.environ["TARGET"]; PORT = int(os.environ.get("PORT", "8089"))
A = os.environ["ACTION"]; U = os.environ.get("UID", "GW"); CS = os.environ.get("CS", U)
N = int(os.environ.get("N", "10")); HOLD = float(os.environ.get("HOLD", "10")); DELAY = float(os.environ.get("DELAY", "0.5"))
EXPECT = os.environ.get("EXPECT", ""); SIZE = int(os.environ.get("SIZE", "70000"))


def ctx():
    c = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT); c.check_hostname = False; c.verify_mode = ssl.CERT_REQUIRED
    c.load_verify_locations(os.environ.get("CA", "/app/ots/ca/ca.pem"))
    c.load_cert_chain(os.environ["CERT"], os.environ["KEY"])
    return c


def ts(t):
    return datetime.datetime.fromtimestamp(t, datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.000Z")


def ev(uid, contact, extra=""):
    n = time.time()
    d = ('<takv device="dv" os="1" platform="ATAK-CIV" version="5.1"/><contact callsign="%s"/>' % CS) if contact else ""
    return ('<event version="2.0" uid="%s" type="a-f-G-U-C" how="h-e" time="%s" start="%s" stale="%s"><point lat="25.03" '
            'lon="121.56" hae="10" ce="9999999" le="9999999"/><detail>%s%s</detail></event>'
            % (uid, ts(n), ts(n), ts(n + 600), d, extra)).encode()


def ping():
    n = time.time()
    return ('<event version="2.0" uid="%s-ping" type="t-x-c-t" how="h-g-i-g-o" time="%s" start="%s" stale="%s">'
            '<point lat="0" lon="0" hae="0" ce="9999999" le="9999999"/><detail/></event>' % (U, ts(n), ts(n), ts(n + 20))).encode()


def connect():
    s = socket.create_connection((T, PORT), timeout=15)
    s = ctx().wrap_socket(s)
    print("PORT", s.getsockname()[1], flush=True)
    return s


def read_until(s, hold, want=None):
    """read for `hold` s; return (bytes, closed, seconds_to_close)"""
    s.settimeout(0.5); buf = b""; t0 = time.time()
    while time.time() - t0 < hold:
        try:
            d = s.recv(65536)
            if not d:
                return buf, True, time.time() - t0
            buf += d
            if want is not None and want(buf):
                break
        except socket.timeout:
            continue
        except OSError:
            return buf, True, time.time() - t0
    return buf, False, time.time() - t0


if A in ("hold", "refused"):
    try:
        s = connect(); s.sendall(ev(U, True))
    except Exception as e:
        print("CLOSED", U, "at connect:", e); sys.exit(0)
    buf, closed, dt = read_until(s, HOLD)
    print(("CLOSED %s after %.1f" if closed else "KEPT %s %.1f") % (U, dt))
    s.close()
elif A == "noread":
    s = connect(); s.sendall(ev(U, True))
    time.sleep(HOLD)
    print("NOREAD", U, "done")
    try:
        s.close()
    except OSError:
        pass
elif A == "stream":
    s = connect(); s.sendall(ev(U, True)); time.sleep(1)
    n = 0
    try:
        for i in range(1, N + 1):
            s.sendall(ev("%s-p%d" % (U, i), False)); n += 1; time.sleep(DELAY)
        time.sleep(HOLD)
    except OSError as e:
        print("CONNLOST after", n, e)
    print("SENT", n); s.close()
elif A == "readcount":
    s = connect(); s.sendall(ev(U, True))
    import re
    pat = re.compile(rb'uid="(%s[^"]*)"' % re.escape(EXPECT.encode()))
    buf, closed, dt = read_until(s, HOLD, want=lambda b: len(set(pat.findall(b))) >= N)
    print("GOT", len(set(pat.findall(buf))), "closed" if closed else "open")
    s.close()
elif A == "pingflood":
    s = connect(); t0 = time.time(); p = ping(); n = 0; ok = 1
    try:
        s.settimeout(20)
        for i in range(N):
            s.sendall(p); n += 1
    except OSError:
        ok = 0
    print("PINGS", n, "%.2f" % (time.time() - t0), "open=%d" % ok); s.close()
elif A == "oversize":
    s = connect(); s.sendall(ev(U, True)); time.sleep(0.5)
    s.sendall(ev(U, False, "<remarks>" + "x" * SIZE + "</remarks>"))
    time.sleep(0.5); s.sendall(ping())
    buf, closed, dt = read_until(s, 5, want=lambda b: b"t-x-c-t-r" in b)
    print("PONG", 1 if b"t-x-c-t-r" in buf else 0, "closed" if closed else "open"); s.close()
elif A == "rawflood":
    socks = []
    for i in range(N):
        try:
            socks.append(socket.create_connection((T, PORT), timeout=5))
        except OSError:
            break
    time.sleep(HOLD)
    k = 0
    for s in socks:
        s.settimeout(0.2)
        try:
            d = s.recv(1)
            if d:
                k += 1          # unexpected data: count as open
        except socket.timeout:
            k += 1              # still open
        except OSError:
            pass
    print("RAW", len(socks), "open=%d" % k)
    for s in socks:
        s.close()
else:
    print("unknown ACTION", A); sys.exit(2)

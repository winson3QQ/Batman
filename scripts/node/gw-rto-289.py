#!/usr/bin/env python3
"""gw-rto-289.py — the RTO walks out of range and comes back (#289 rto-289), run INSIDE an OTS container on the OTS
node (python3 + ssl), one process so the node's ssh limit is not hit:
  docker exec -i -e TARGET=172.20.0.10 -e RUN=<id> -e USERS="u1 u2 u3 u4" -e RTO=u5 [-e PER=4 -e T1=30 -e HOLD2=150]
      ots_cot_parser python3 - < this      (certs at /tmp/<user>.pem|key)
Timeline (all from this process):
  t=0     the RTO's own phone (user RTO, uid RUN-R) connects and reads for the whole run (the 17th client)
  t=0     16 phones (USERS x PER, uid RUN-u<k>-<j>) connect, identify, then NEVER read and send a ping every 5 s
          (their writes are what the node's black hole drops: the proof that it bites); prints "PORT <uid> <port>"
  t=T1    "PHASE2" — by now the harness has black-holed the 16 ports; the same 16 phones reconnect (same user, same
          uid) and read for HOLD2 s, counting the team's stream (events RUN-T-p<i>)
  t=T1+10 a teammate (user RTO, uid RUN-T) streams 10 events, 1 s apart
  end     prints "GOT <uid> <n>" per returned phone, "RTO GOT <n> <kept|closed>", "OLD <open>/<16> still open here"
"""
import os
import re
import socket
import ssl
import threading
import time
import datetime

T = os.environ["TARGET"]; RUN = os.environ["RUN"]; USERS = os.environ["USERS"].split(); RTO = os.environ["RTO"]
PER = int(os.environ.get("PER", "4")); T1 = float(os.environ.get("T1", "30")); HOLD2 = float(os.environ.get("HOLD2", "150"))
PORT = 8089
lock = threading.Lock()


def out(*a):
    with lock:
        print(*a, flush=True)


def ctx(user):
    c = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT); c.check_hostname = False; c.verify_mode = ssl.CERT_REQUIRED
    c.load_verify_locations("/app/ots/ca/ca.pem"); c.load_cert_chain("/tmp/%s.pem" % user, "/tmp/%s.key" % user)
    return c


def ts(t):
    return datetime.datetime.fromtimestamp(t, datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.000Z")


def ev(uid, contact=True):
    n = time.time()
    d = ('<takv device="dv" os="1" platform="ATAK-CIV" version="5.1"/><contact callsign="%s"/>' % uid) if contact else ""
    return ('<event version="2.0" uid="%s" type="a-f-G-U-C" how="h-e" time="%s" start="%s" stale="%s"><point lat="25.03" '
            'lon="121.56" hae="10" ce="9999999" le="9999999"/><detail>%s</detail></event>' % (uid, ts(n), ts(n), ts(n + 600), d)).encode()


def ping(uid):
    n = time.time()
    return ('<event version="2.0" uid="%s-ping" type="t-x-c-t" how="h-g-i-g-o" time="%s" start="%s" stale="%s"><point lat="0" '
            'lon="0" hae="0" ce="9999999" le="9999999"/><detail/></event>' % (uid, ts(n), ts(n), ts(n + 20))).encode()


def conn(user):
    return ctx(user).wrap_socket(socket.create_connection((T, PORT), timeout=15))


pat = re.compile(rb'uid="(%s-T-p[0-9]+)"' % re.escape(RUN.encode()))
results = {}
old = []


def reader(user, uid, hold, key):
    try:
        s = conn(user); s.sendall(ev(uid)); s.settimeout(0.5)
    except Exception as e:
        results[key] = ("ERR", 0, str(e)[:60]); return
    buf = b""; t0 = time.time(); closed = False
    while time.time() - t0 < hold:
        try:
            d = s.recv(65536)
            if not d:
                closed = True; break
            buf += d
        except socket.timeout:
            continue
        except OSError:
            closed = True; break
    results[key] = ("closed" if closed else "kept", len(set(pat.findall(buf))), "")
    try:
        s.close()
    except OSError:
        pass


def stale(user, uid, hold):
    try:
        s = conn(user); s.sendall(ev(uid))
    except Exception as e:
        out("STALE-ERR", uid, e); return
    old.append(s)
    out("PORT", uid, s.getsockname()[1])
    t0 = time.time()
    while time.time() - t0 < hold:
        time.sleep(5)
        try:
            s.settimeout(1); s.sendall(ping(uid))   # dropped by the black hole: the drop counter's proof
        except OSError:
            pass


phones = [(u, "%s-%s-%d" % (RUN, u.split("-")[-1], j)) for u in USERS for j in range(1, PER + 1)]
th = [threading.Thread(target=reader, args=(RTO, RUN + "-R", T1 + HOLD2 + 5, "RTO"), daemon=True)]
th[0].start()
for u, uid in phones:
    t = threading.Thread(target=stale, args=(u, uid, T1 + HOLD2), daemon=True); t.start(); time.sleep(0.1)
time.sleep(T1)
out("PHASE2", len(old))
ret = []
for u, uid in phones:
    t = threading.Thread(target=reader, args=(u, uid, HOLD2, uid), daemon=True); t.start(); ret.append(t); time.sleep(0.05)
time.sleep(10)
try:
    s = conn(RTO); s.sendall(ev(RUN + "-T")); time.sleep(1)
    for i in range(1, 11):
        s.sendall(ev("%s-T-p%d" % (RUN, i), contact=False)); time.sleep(1)
    time.sleep(3); s.close(); out("STREAM 10")
except Exception as e:
    out("STREAM-ERR", e)
for t in ret:
    t.join()
for u, uid in phones:
    r = results.get(uid, ("none", 0, ""))
    out("GOT", uid, r[1], r[0], r[2])
th[0].join(timeout=10)
r = results.get("RTO", ("none", 0, ""))
out("RTO GOT", r[1], r[0])
alive = 0
for s in old:
    try:
        s.settimeout(0.2); s.recv(1); alive += 0
    except socket.timeout:
        alive += 1
    except OSError:
        pass
out("OLD %d/%d still open here" % (alive, len(old)))

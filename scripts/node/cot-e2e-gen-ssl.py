#!/usr/bin/env python3
"""cot-e2e-gen-ssl.py — the #264/#268 CoT generator for the SSL listener (8089). Same three phases as
cot-e2e-gen.sh (P1 control 30, P2 truncation 20 pairs A+half-B / rest-of-B, P3 20 x 5-event bursts) on
mutually-authenticated TLS. Each write is one sendall() = one TLS record, so the server's recv() sees the
same boundaries as with the plain-TCP generator (P2 deterministically hits #264 mechanism A).

Runs INSIDE an OTS container (python3 + ssl present), e.g. from the OTS node:
  docker exec -i -e TARGET=172.20.0.12 -e RUN=DVS... -e CERT=... -e KEY=... -e CA=... \
      ots_cot_parser python3 - < cot-e2e-gen-ssl.py
CERT/KEY: a client certificate issued by the OTS CA whose CN is an existing OTS user (the SSL handler
maps the CN to the user). Output lines: "SENT <phase> <n>" and "CONNLOST <phase> <seq>" (as the sh version).
"""
import os, socket, ssl, time, datetime

T, RUN = os.environ["TARGET"], os.environ["RUN"]
PORT = int(os.environ.get("PORT", "8089"))
ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
ctx.check_hostname = False
ctx.verify_mode = ssl.CERT_REQUIRED
ctx.load_verify_locations(os.environ["CA"])
ctx.load_cert_chain(os.environ["CERT"], os.environ["KEY"])


def ts(t):
    return datetime.datetime.fromtimestamp(t, datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.000Z")


def head_of(u):
    return '<event version="2.0" uid="%s" type="a-' % u


def tail_of(u):
    n = time.time()
    return ('f-G-U-C" how="h-e" time="%s" start="%s" stale="%s"><point lat="25.03" lon="121.56" hae="10" '
            'ce="9999999" le="9999999"/><detail><contact callsign="%s"/><marti><dest callsign="dv-nobody"/>'
            '</marti></detail></event>' % (ts(n), ts(n), ts(n + 60), u))


def ev(u):
    return head_of(u) + tail_of(u)


class Conn:
    def __init__(self):
        raw = socket.create_connection((T, PORT), timeout=10)
        self.s = ctx.wrap_socket(raw)
        self.s.settimeout(0.2)
        self.lost = False

    def w(self, data):
        if self.lost:
            return False
        try:
            self.s.sendall(data.encode("utf-8"))
            try:                                  # a server-side close shows up as EOF / reset
                if self.s.recv(4096) == b"":
                    self.lost = True
            except (socket.timeout, ssl.SSLWantReadError):
                pass
            return not self.lost
        except (OSError, ssl.SSLError):
            self.lost = True
            return False

    def close(self):
        time.sleep(3)
        try:
            self.s.close()
        except OSError:
            pass


def lost(c, ph, k):
    print("CONNLOST %s %s" % (ph, k), flush=True)


# P1 control
c = Conn(); s = 0
for k in range(1, 31):
    if not c.w(ev("%s-P1-%d" % (RUN, k))):
        lost(c, "P1", k); break
    s += 1; time.sleep(1)
c.close(); print("SENT P1 %d" % s, flush=True)

# P2 deterministic truncation
c = Conn(); sa = sb = 0
for k in range(1, 21):
    if not c.w(ev("%s-P2-%dA" % (RUN, k)) + head_of("%s-P2-%dB" % (RUN, k))):
        lost(c, "P2", "%dA" % k); break
    sa += 1; time.sleep(1)
    if not c.w(tail_of("%s-P2-%dB" % (RUN, k))):
        lost(c, "P2", "%dB" % k); break
    sb += 1; time.sleep(1)
c.close(); print("SENT P2A %d" % sa, flush=True); print("SENT P2B %d" % sb, flush=True)

# P3 burst
c = Conn(); s = 0
for k in range(1, 21):
    if not c.w("".join(ev("%s-P3-%d-%d" % (RUN, k, j)) for j in range(1, 6))):
        lost(c, "P3", k); break
    s += 5; time.sleep(1)
c.close(); print("SENT P3 %d" % s, flush=True)

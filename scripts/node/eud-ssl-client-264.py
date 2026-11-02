#!/usr/bin/env python3
"""eud-ssl-client-264.py — an 8089 test session for the #264 suites (runs INSIDE an OTS container, python3 + ssl):
identifies as $V/$VC, then sends $N plain events (uid $V-p<i>, no contact) $DELAY s apart, holds $HOLD s, closes.
CERT/KEY: a test client certificate from ots-test-client-cert.py. Prints "closed <uid> sent <n>"."""
import datetime, os, socket, ssl, time
T, V, VC, N = os.environ["TARGET"], os.environ["V"], os.environ["VC"], int(os.environ.get("N", "0"))
ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT); ctx.check_hostname = False; ctx.verify_mode = ssl.CERT_REQUIRED
ctx.load_verify_locations(os.environ["CA"]); ctx.load_cert_chain(os.environ["CERT"], os.environ["KEY"])
def ts(t): return datetime.datetime.fromtimestamp(t, datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.000Z")
def ev(uid, contact):
    n = time.time()
    d = '<contact callsign="%s"/>' % VC if contact else ""
    return ('<event version="2.0" uid="%s" type="a-f-G-U-C" how="h-e" time="%s" start="%s" stale="%s"><point lat="25.03" '
            'lon="121.56" hae="10" ce="9999999" le="9999999"/><detail>%s</detail></event>' % (uid, ts(n), ts(n), ts(n + 600), d))
s = ctx.wrap_socket(socket.create_connection((T, 8089), timeout=10))
s.sendall(ev(V, True).encode()); time.sleep(2)
for i in range(1, N + 1):
    s.sendall(ev("%s-p%d" % (V, i), False).encode()); time.sleep(float(os.environ.get("DELAY", "0.5")))
time.sleep(float(os.environ.get("HOLD", "5"))); s.close(); print("closed", V, "sent", 1 + N)

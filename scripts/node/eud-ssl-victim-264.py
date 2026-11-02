#!/usr/bin/env python3
"""eud-ssl-victim-264.py — one authenticated 8089 EUD session for the #264 review-round-2 suites.

Runs INSIDE an OTS container (python3 + ssl), e.g. from the OTS node:
  docker exec -i -e TARGET=172.20.0.12 -e V=<uid> -e VC=<callsign> -e HOLD=<s> -e CA=.. -e CERT=.. -e KEY=.. \
      ots_cot_parser python3 - < eud-ssl-victim-264.py
CERT/KEY: a test client certificate issued by ots-test-client-cert.py (CN = an existing OTS user). The session
identifies once as uid $V / callsign $VC, holds HOLD seconds and closes. Prints "VICTIM closed <uid> <callsign>".
"""
import datetime, os, socket, ssl, time

T, V, VC = os.environ["TARGET"], os.environ["V"], os.environ["VC"]
ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
ctx.check_hostname = False
ctx.verify_mode = ssl.CERT_REQUIRED
ctx.load_verify_locations(os.environ["CA"])
ctx.load_cert_chain(os.environ["CERT"], os.environ["KEY"])


def ts(t):
    return datetime.datetime.fromtimestamp(t, datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.000Z")


n = time.time()
ev = ('<event version="2.0" uid="%s" type="a-f-G-U-C" how="h-e" time="%s" start="%s" stale="%s"><point lat="25.03" '
      'lon="121.56" hae="10" ce="9999999" le="9999999"/><detail><contact callsign="%s"/></detail></event>'
      % (V, ts(n), ts(n), ts(n + 600), VC))
s = ctx.wrap_socket(socket.create_connection((T, int(os.environ.get("PORT", "8089"))), timeout=10))
s.sendall(ev.encode())
time.sleep(float(os.environ.get("HOLD", "5")))
s.close()
print("VICTIM closed", V, VC)

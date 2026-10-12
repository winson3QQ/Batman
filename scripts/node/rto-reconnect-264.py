# rto-reconnect-264.py — the reconnect side of the "RTO returns" suites, run inside an OTS container (python3):
#   docker exec -i -e TARGET=<ip> -e RUN=<id> -e FIRST=<k> -e N=8 -e HOLD=120 [-e PORT=8089 -e CA= -e CERT= -e KEY=]
#     <container> python3 - < this
# Opens N identifying sessions (uid/callsign $RUN-<k>, k = FIRST..FIRST+N-1: the SAME uids as the stale sessions,
# i.e. the phones reconnecting), all at once, holds them HOLD s, and reports per session whether the server kept it
# (connected for the whole hold) or closed it (refused). PORT 8089: mTLS with the test client certificate.
import os, socket, ssl, threading, time, datetime

T, RUN = os.environ["TARGET"], os.environ["RUN"]
FIRST, N, HOLD = int(os.environ.get("FIRST", "1")), int(os.environ.get("N", "8")), int(os.environ.get("HOLD", "120"))
PORT = int(os.environ.get("PORT", "8088"))
ctx = None
if PORT == 8089:
    ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT); ctx.check_hostname = False; ctx.verify_mode = ssl.CERT_REQUIRED
    ctx.load_verify_locations(os.environ["CA"]); ctx.load_cert_chain(os.environ["CERT"], os.environ["KEY"])


def ev(u):
    n = datetime.datetime.now(datetime.timezone.utc)
    f = lambda d: d.strftime("%Y-%m-%dT%H:%M:%S.000Z")
    return ('<event version="2.0" uid="%s" type="a-f-G-U-C" how="h-e" time="%s" start="%s" stale="%s"><point lat="25.03" '
            'lon="121.56" hae="10" ce="9999999" le="9999999"/><detail><contact callsign="%s"/></detail></event>'
            % (u, f(n), f(n), f(n + datetime.timedelta(seconds=600)), u)).encode()


res = {}


def one(k):
    u = "%s-%d" % (RUN, k)
    try:
        s = socket.create_connection((T, PORT), timeout=15)
        if ctx is not None:
            s = ctx.wrap_socket(s)
        s.sendall(ev(u))
        s.settimeout(1)
        end = time.time() + HOLD
        while time.time() < end:
            try:
                d = s.recv(65536)
                if not d:
                    res[u] = "closed after %.0f s" % (HOLD - (end - time.time())); return
            except socket.timeout:
                pass
        res[u] = "kept"; s.close()
    except Exception as e:
        res[u] = "error %s" % e


th = [threading.Thread(target=one, args=(k,)) for k in range(FIRST, FIRST + N)]
for t in th: t.start()
for t in th: t.join()
for u in sorted(res): print(u, res[u])
print("KEPT %d / %d" % (sum(v == "kept" for v in res.values()), N))

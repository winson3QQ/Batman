# rto-downlink-264.py — the downlink generator of rto-264 / rto-ssl-264, run inside ots_eud_handler_ssl (python3):
#   docker exec -i -e TARGET=172.20.0.10 -e RUN=<id> ots_eud_handler_ssl python3 - < this
# One 8088 session: identifies as $RUN-g, then 20 broadcasts (uid $RUN-<i>, no contact) 1 s apart, so the stale
# sessions have data pending towards them (as zombie-264's D does). Prints "SENT 20".
import datetime, os, socket, time
T, RUN = os.environ["TARGET"], os.environ["RUN"]
def ev(u, cs=None):
    n = datetime.datetime.now(datetime.timezone.utc); f = lambda d: d.strftime("%Y-%m-%dT%H:%M:%S.000Z")
    c = '<contact callsign="%s"/>' % cs if cs else ""
    return ('<event version="2.0" uid="%s" type="a-f-G-U-C" how="h-e" time="%s" start="%s" stale="%s"><point lat="25.03" '
            'lon="121.56" hae="10" ce="9999999" le="9999999"/><detail>%s</detail></event>'
            % (u, f(n), f(n), f(n + datetime.timedelta(seconds=600)), c)).encode()
s = socket.create_connection((T, 8088), timeout=10); s.sendall(ev(RUN + "-g", RUN + "-g")); time.sleep(2)
for i in range(1, 21):
    s.sendall(ev("%s-%d" % (RUN, i))); time.sleep(1)
time.sleep(2); s.close(); print("SENT 20")

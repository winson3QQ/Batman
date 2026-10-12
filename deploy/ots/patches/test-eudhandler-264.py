"""Offline test of the PATCHED EudHandler.handle(), extracted verbatim (ast) from the patched file."""
import ast, sys, textwrap, logging
from xml.etree.ElementTree import fromstring, ParseError

src = open(sys.argv[1], encoding="utf-8").read()
mod = ast.parse(src)
cls = next(n for n in mod.body if isinstance(n, ast.ClassDef) and n.name == "EudHandler")
code = ""
for name in ("handle", "_handle_loop"):   # round 3: handle() wraps the loop in try/finally
    fns = [n for n in cls.body if isinstance(n, ast.FunctionDef) and n.name == name]
    code += (textwrap.dedent(ast.get_source_segment(src, fns[0])) + "\n") if fns else ""
import socket as _socket, time as _time
import traceback as _tb
g = {"fromstring": fromstring, "ParseError": ParseError, "MAX_PENDING": 1 << 20, "time": _time, "socket_mod": _socket,
     "IDENT_MAX_S": 60, "traceback": _tb}
exec(code, g)
handle = g["handle"]

class Sock:
    def __init__(self, chunks): self.c = list(chunks); self.timeouts = []
    def recv(self, n):
        if self.c and self.c[0] == "TIMEOUT":
            self.c.pop(0); raise _socket.timeout("timed out")
        return self.c.pop(0) if self.c else b""
    def settimeout(self, t): self.timeouts.append(t)

class H:
    def __init__(self, chunks):
        self.request = Sock(chunks); self.shutdown = False; self.got = []; self.auth = []
        self.logger = logging.getLogger("t"); self.client_address = ("x", 0); self.closed = 0; self.waited = 0
        self.uid = None; self.released = 0; self.raise_on = None; self._sub_wanted = False
        if "_handle_loop" in g: self._handle_loop = g["_handle_loop"].__get__(self)
    def handle_cot(self, m):
        if self.raise_on and self.raise_on in m: raise KeyError("start")
        self.got.append(m)
        if "<contact" in m:   # identified and its subscription requested, as parse_device_info does
            self.uid = m.split('uid="')[1].split('"')[0]; self._sub_wanted = True
    def _release_admit(self): self.released += 1
    def handle_auth(self, m): self.auth.append(m)
    def close_connection(self): self.closed += 1
    def _wait_end(self): self.waited += 1

def ev(u, cs=None, decl=True):
    cs = cs or u
    e = ('<event version="2.0" uid="%s" type="a-f-G-U-C" how="h-e" time="T" start="T" stale="T"><point lat="25.03" '
         'lon="121.56" hae="10" ce="9999999" le="9999999"/><detail><contact callsign="%s"/></detail></event>' % (u, cs))
    return (('<?xml version="1.0" encoding="UTF-8"?>' if decl else "") + e).encode("utf-8")

def run(name, chunks, want_uids, want_auth=0):
    h = H(chunks); handle(h)
    uids = [m.split('uid="')[1].split('"')[0] for m in h.got]
    ok = uids == want_uids and len(h.auth) == want_auth and h.closed == 1
    print(("PASS" if ok else "FAIL"), f"{name}: stored {len(uids)}/{len(want_uids)} auth={len(h.auth)}/{want_auth} close={h.closed}")
    if not ok: print("   got", uids[:8], "...")
    return ok

def split(b, n): return [b[i:i + n] for i in range(0, len(b), n)]

R = []
s500 = b"".join(ev("U%d" % i) for i in range(500)); u500 = ["U%d" % i for i in range(500)]
for n in (65536, 4096, 1460, 1024, 333, 1):
    R.append(run(f"500 events in {n}-byte recvs", split(s500, n), u500))
# P2: A + first half of B / rest of B
pairs = []
for i in range(20):
    a, b = ev("A%d" % i), ev("B%d" % i); h = b.index(b'type="a-') + 8; pairs += [a + b[:h], b[h:]]
R.append(run("P2 A+halfB / halfB", pairs, [x for i in range(20) for x in ("A%d" % i, "B%d" % i)]))
# half / half
hh = []
for i in range(20):
    b = ev("H%d" % i); h = b.index(b'type="a-') + 8; hh += [b[:h], b[h:]]
R.append(run("half / half", hh, ["H%d" % i for i in range(20)]))
# Chinese callsign, one byte per recv (multi-byte UTF-8 split everywhere)
zh = ev("Z1", "測試小隊一") + ev("Z2", "台北")
R.append(run("Chinese callsign, 1-byte recvs", split(zh, 1), ["Z1", "Z2"]))
h = H(split(zh, 1)); handle(h); print("   callsign intact:", "測試小隊一" in h.got[0])
# no XML declaration, and whitespace/newlines between events
R.append(run("no decl + newlines", [ev("N1", decl=False) + b"\n  " + ev("N2", decl=False) + b"\r\n"], ["N1", "N2"]))
# <auth> and <event> in one write
auth = b'<auth><cot username="u" password="p" uid="X"/></auth>'
R.append(run("auth + event in one write", [auth + ev("E1")], ["E1"], want_auth=1))
# a malformed event followed by a good one: only the bad one is dropped
bad = b'<event version="2.0" uid="BAD" type="a-f-G"><point lat="x"/><detail></event>'
R.append(run("malformed then good", [bad + ev("G1")], ["G1"]))
# event missing its close, then a good one: the good one must survive (rfind)
R.append(run("unterminated then good", [b'<?xml version="1.0"?><event uid="LOST" ' + ev("G2")], ["G2"]))
# > 1 MiB without a closing tag is dropped, the stream continues
R.append(run(">1 MiB pending dropped", [b"<event " + b"x" * 1100000, ev("AFTER")], ["AFTER"]))
# R12: a client that sends no complete message by the deadline is closed; the handler always waits for the end
h = H(["TIMEOUT"]); handle(h)
c = h.closed == 1 and h.waited == 1 and not h.got and len(h.request.timeouts) == 1 and 0 < h.request.timeouts[0] <= 60
print(("PASS" if c else "FAIL"), f"R12 silent client: closed at the deadline (timeouts {h.request.timeouts}), end waited"); R.append(c)
# R12 (review r3 B3-3): until the client identifies, each complete message only moves the deadline on (it is armed
# again, never cleared); identification clears it once
def plain(u): return ('<event version="2.0" uid="%s" type="a-f-G-U-C"><point lat="1" lon="1"/><detail/></event>' % u).encode()
h = H([b"<event></event>", plain("P1"), b"<event></event>"]); handle(h)
c = None not in h.request.timeouts and len(h.request.timeouts) == 4 and h.uid is None and h.closed == 1
print(("PASS" if c else "FAIL"), f"R12 unidentified chatter: deadline re-armed on every recv, never cleared (timeouts {h.request.timeouts})"); R.append(c)
h = H([ev("Q1")[:30], ev("Q1")[30:], ev("Q2")]); handle(h)
c = [m.split('uid="')[1].split('"')[0] for m in h.got] == ["Q1", "Q2"] and h.request.timeouts.count(None) == 1 and h.request.timeouts[-1] is None and h.waited == 1
print(("PASS" if c else "FAIL"), f"R12 identifying client: deadline cleared once at identification (timeouts {h.request.timeouts})"); R.append(c)
# R16: a session that requested its subscription keeps the admission lock (released by _subscribe once placed, or by
# the end); a session that does not identify releases it at its first complete message
c = h.released == 1
print(("PASS" if c else "FAIL"), f"R16 identifying client: the admission lock is not released by the messages, only at the end here (released {h.released}x)"); R.append(c)
h = H([plain("N1"), plain("N2")]); handle(h)
c = h.released == 3 and h.uid is None
print(("PASS" if c else "FAIL"), f"R16 non-identifying client: released at each message and at the end (released {h.released}x)"); R.append(c)
# A3-2 (review r3): an exception out of handle_cot drops that message only; the session goes on and still ends properly
h = H([ev("BAD1") + ev("OK1")]); h.raise_on = 'uid="BAD1"'; handle(h)
c = [m.split('uid="')[1].split('"')[0] for m in h.got] == ["OK1"] and h.closed == 1 and h.waited == 1
print(("PASS" if c else "FAIL"), "A3-2 a raising message is dropped, the next one handled, the end runs and is waited for"); R.append(c)
class Boom(Exception): pass
h = H([ev("Z")]); h._handle_loop = lambda *a: (_ for _ in ()).throw(Boom("loop died"))
try:
    handle(h)
except Exception:
    pass
c = h.closed == 1 and h.waited == 1 and h.released >= 1
print(("PASS" if c else "FAIL"), "A3-2 whatever leaves the loop: the end runs, is waited for, the admission lock released"); R.append(c)
print("ALL PASS" if all(R) else "SOME FAILED")

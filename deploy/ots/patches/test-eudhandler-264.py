"""Offline test of the PATCHED EudHandler.handle(), extracted verbatim (ast) from the patched file."""
import ast, sys, textwrap, logging
from xml.etree.ElementTree import fromstring, ParseError

src = open(sys.argv[1], encoding="utf-8").read()
mod = ast.parse(src)
cls = next(n for n in mod.body if isinstance(n, ast.ClassDef) and n.name == "EudHandler")
fn = next(n for n in cls.body if isinstance(n, ast.FunctionDef) and n.name == "handle")
code = textwrap.dedent(ast.get_source_segment(src, fn))
g = {"fromstring": fromstring, "ParseError": ParseError, "MAX_PENDING": 1 << 20}
exec(code, g)
handle = g["handle"]

class Sock:
    def __init__(self, chunks): self.c = list(chunks)
    def recv(self, n): return self.c.pop(0) if self.c else b""

class H:
    def __init__(self, chunks):
        self.request = Sock(chunks); self.shutdown = False; self.got = []; self.auth = []
        self.logger = logging.getLogger("t"); self.client_address = ("x", 0); self.closed = 0
    def handle_cot(self, m): self.got.append(m)
    def handle_auth(self, m): self.auth.append(m)
    def close_connection(self): self.closed += 1

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
print("ALL PASS" if all(R) else "SOME FAILED")

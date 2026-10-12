"""Offline regression for R14 (review r5 A5-2/B5-1; adapted from reviewer A5's probe): an 8088 client whose identifying CoT always raises inside parse_device_info
AFTER the subscription was requested (here: <__group name=..> without role -> KeyError at the row write).
Extracts handle_cot / parse_device_info verbatim (ast) from the overlay; DB / soup are minimal fakes.
Measures, per CoT: parse_device_info runs, bound_queues length, subscription requests, engine disposals."""
import ast, sys, textwrap, logging, types, contextlib

src = open(sys.argv[1], encoding="utf-8").read()
mod = ast.parse(src)
cls = next(n for n in mod.body if isinstance(n, ast.ClassDef) and n.name == "EudHandler")
code = ""
for name in ("handle_cot", "parse_device_info"):
    fn = next(n for n in cls.body if isinstance(n, ast.FunctionDef) and n.name == name)
    code += textwrap.dedent(ast.get_source_segment(src, fn)) + "\n"
vfn = next(n for n in mod.body if isinstance(n, ast.FunctionDef) and n.name == "_valid_name")
code += ast.get_source_segment(src, vfn) + "\n"
rn = next(n for n in mod.body if isinstance(n, ast.Assign) and getattr(n.targets[0], "id", "") == "RESERVED_NAMES")
code = ast.get_source_segment(src, rn) + "\n" + code


class Tag:
    def __init__(self, attrs, kids=None): self.attrs = attrs; self.kids = kids or {}
    def find(self, n): return self.kids.get(n)
    def __bool__(self): return True
    def __str__(self): return "<event/>"


def soup_of(cot):
    return types.SimpleNamespace(find=lambda n: EVENT)


class Col:
    def __eq__(self, o): return self
    def __ne__(self, o): return self
    def in_(self, o): return self
    def isnot(self, o): return self
    def __or__(self, o): return self
    __hash__ = object.__hash__


class Row:
    uid = Col(); callsign = Col(); user_id = Col(); name = Col(); meshtastic_id = None; id = 1
    def serialize(self): return {}
    def to_json(self): return {}


class Q:
    def filter(self, *a): return self
    def filter_by(self, **k): return self


class Res:
    def first(self): return None
    def all(self): return []


import os as _os
class Sess:
    disposed = 0; commits = 0
    def execute(self, *a): return Res()
    def add(self, x): pass
    def commit(self):
        if _os.environ.get("COMMIT_FAILS"): raise ValueError("DataError: invalid input syntax for type bigint")
        Sess.commits += 1
    def rollback(self): pass
    def close(self): pass


class DB:
    session = Sess()
    class engine:
        n = 0
        @staticmethod
        def dispose(): DB.engine.n += 1


def bad_dt(s): return s


g = {"BeautifulSoup": lambda c, p: soup_of(c), "db": DB, "select": lambda *a: Q(), "update": lambda *a: Q(),
     "EUD": Row, "Team": Row, "Chatroom": Row, "GroupUser": Row, "Group": types.SimpleNamespace(OUT="OUT"),
     "bleach": types.SimpleNamespace(clean=lambda s: s), "datetime_from_iso8601_string": bad_dt,
     "sqlalchemy": types.SimpleNamespace(exc=types.SimpleNamespace(IntegrityError=type("IE", (Exception,), {}))),
     "traceback": __import__("traceback"), "os": __import__("os"), "base64": __import__("base64"),
     "json": __import__("json"), "re": __import__("re"), "uuid": __import__("uuid"), "_OpRecorder": None}
# _OpRecorder verbatim too
orc = next(n for n in mod.body if isinstance(n, ast.ClassDef) and n.name == "_OpRecorder")
exec(ast.get_source_segment(src, orc), g)
exec(code, g)
_pf = next((n for n in mod.body if isinstance(n, ast.FunctionDef) and n.name == "_phone_int"), None)
if _pf: exec(ast.get_source_segment(src, _pf), g)


class H:
    is_ssl = False; is_authenticated = False; user = None; uid = None; callsign = None; phone_number = None
    rabbit_channel = None; client_address = ("10.41.24.32", 4242); common_name = None

    def __init__(self):
        self.bound_queues = []; self.group_memberships = []; self._squat_logged = False; self._relay = False
        self._cs_queue = True; self._sub_wanted = False; self.subreq = 0; self.pubs = 0; self.pdi = 0
        self._ident_failures = 0; self.minimal = 0; self._row_next = 0.0; self.claims = 0
        self.logger = logging.getLogger("a5"); self.app = types.SimpleNamespace(app_context=contextlib.nullcontext)
    def _minimal_eud_row(self, uid): self.minimal += 1
    def _fi(self, uid, stage): pass
    def _claim(self, uid): self.claims += 1; return True
    def pong(self, e): return False
    def on_message(self, *a): pass
    def _owned_by_user(self, u, c): return (False, False) if "cs_owned" in src else False
    def _subscribe(self, *a): pass
    def _io(self, fn, *a): self.subreq += 1; return True
    def publish_cot(self, e): self.pubs += 1

H.handle_cot = g["handle_cot"]
_pdi = g["parse_device_info"]
def counted(self, ev): self.pdi += 1; return _pdi(self, ev)
H.parse_device_info = counted

MSGS = []
class Rec(logging.Handler):
    def emit(self, r): MSGS.append(r.getMessage())
lg = logging.getLogger("a5"); lg.addHandler(Rec()); lg.setLevel(logging.ERROR); lg.propagate = False
EVENT = Tag({"uid": "ANDROID-abc", "type": "a-f-G-U-C", "start": "2026-10-12T00:00:00Z"},
            {"contact": Tag({"callsign": "Alpha"}), "__group": Tag({"name": "Cyan"})})  # no role attribute
P = F = 0
def ok(c, m):
    global P, F
    P += bool(c); F += (not c); print(("PASS" if c else "FAIL"), m)

for fails in (False, True):
    _os.environ.pop("COMMIT_FAILS", None)
    if fails: _os.environ["COMMIT_FAILS"] = "1"
    Sess.commits = 0; DB.engine.n = 0; MSGS.clear()
    h = H()
    for _ in range(1000):
        try:
            h.handle_cot("<event/>")
        except Exception:
            pass
    what = "every row commit raises (a DataError: phone '555-...' in a BigInteger)" if fails else "a __group without role"
    ok(h.pdi == 1 and DB.engine.n == 1 and h.subreq == 1 and len(h.bound_queues) == 4 and h.pubs == 1000,
       f"R14 r5 {what}: identified once in 1000 CoT (runs {h.pdi}, disposals {DB.engine.n}), every CoT published")
    ok((h.minimal == 1 and Sess.commits == 0) if fails else (h.minimal == 0 and Sess.commits >= 1),
       f"R14 r5 {what}: recorded ({'minimal row' if fails else 'full row'}; commits {Sess.commits}, minimal {h.minimal})")
_os.environ.pop("COMMIT_FAILS", None)

# review r6 B6-5 / A6-6: the REAL _minimal_eud_row (verbatim from the overlay) against a fake session that records
# rollbacks and can refuse the insert with or without the callsign
mfn = next(n for n in cls.body if isinstance(n, ast.FunctionDef) and n.name == "_minimal_eud_row")
class MSess:
    def __init__(self, exists=False, fail_with_cs=False, fail_all=False):
        self.exists, self.fail_with_cs, self.fail_all = exists, fail_with_cs, fail_all
        self.rollbacks = 0; self.added = []; self.committed = []
    def rollback(self): self.rollbacks += 1
    def execute(self, *a): return types.SimpleNamespace(first=lambda: (Row(),) if self.exists else None)
    def add(self, e): self.added.append(e)
    def commit(self):
        e = self.added[-1]
        if self.fail_all or (self.fail_with_cs and getattr(e, "callsign", None)):
            raise ValueError("IntegrityError: duplicate key value violates unique constraint euds_callsign_key")
        self.committed.append(e)
class MRow:
    uid = None
class Clock:
    t = 1000.0
    @staticmethod
    def monotonic(): return Clock.t
mg = {"db": None, "select": lambda *a: Q(), "EUD": MRow, "time": Clock}
exec(textwrap.dedent(ast.get_source_segment(src, mfn)), mg)
class M:
    callsign = "Alpha"; user = None; uid = None
    def __init__(self, sess):
        self.logger = logging.getLogger("a5"); self.app = types.SimpleNamespace(app_context=contextlib.nullcontext)
        self._row_next = 0.0; mg["db"] = types.SimpleNamespace(session=sess)
M._minimal_eud_row = mg["_minimal_eud_row"]
ss = MSess(exists=True); m = M(ss); r = m._minimal_eud_row("U1")
ok(r is True and not ss.added and m._row_next == 0.0, f"R14 r6 minimal row: an existing row is kept, nothing added (returned {r})")
ss = MSess(fail_with_cs=True); m = M(ss); r = m._minimal_eud_row("U2")
c = ss.committed and getattr(ss.committed[0], "callsign", None) is None and ss.committed[0].uid == "U2"
ok(r is True and c and ss.rollbacks >= 2, f"R14 r6 minimal row: callsign taken -> written without it after a rollback (rollbacks {ss.rollbacks})")
ss = MSess(fail_all=True); m = M(ss); r = m._minimal_eud_row("U3")
ok(r is False and m._row_next == Clock.t + 30, f"R14 r6 minimal row: the database refuses -> False, retry due in 30 s (next {m._row_next - Clock.t})")
ss.fail_all = False; r = m._minimal_eud_row("U3")
ok(r is True and m._row_next == 0.0 and ss.committed[-1].uid == "U3", "R14 r6 minimal row: the retry writes it and clears the retry")
# handle_cot retries a missing row once due, not on every CoT
gh = g; gh["time"] = Clock
h = H(); h.uid = "U4"; h._row_next = Clock.t + 30; h.minimal = 0
h.handle_cot("<event/>"); n0 = h.minimal
Clock.t += 31; d0 = DB.engine.n; h.handle_cot("<event/>")
ok(n0 == 0 and h.minimal == 1, f"R14 r6 handle_cot retries the missing row only when due (before {n0}, after {h.minimal})")
ok(DB.engine.n == d0 + 1, f"R14 r7 A7-9: the retry keeps no postgres connection (engine disposed {DB.engine.n - d0}x)")
print("ALL PASS" if F == 0 else "SOME FAILED (%d)" % F)

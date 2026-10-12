"""Offline regression for R17 (review r6 A6-2/A6-4/B6-6, r7; the user's decision 2026-10-12): one downlink per device.
Extracts _proc_start and the R17 methods verbatim (ast) from the overlay and drives them with real processes: every
session is a forked child (so process start ticks order them as on the node), installs the overlay's _on_supersede for
SIGUSR1, reads its socket like the handler (recording the time of each byte) and answers commands from the test over a
pipe. SUPERSEDE_QUIET_S is 2 s and SUPERSEDE_MAX_S 6 s here (20 s and 120 s in the overlay)."""
import ast, sys, textwrap, logging, os, signal, socket, tempfile, time, types, hashlib, threading, select

src = open(sys.argv[1], encoding="utf-8").read()
mod = ast.parse(src)
cls = next(n for n in mod.body if isinstance(n, ast.ClassDef) and n.name == "EudHandler")
QUIET = 2
MAXW = 6
g = {"os": os, "signal": signal, "hashlib": hashlib, "SHUT_RDWR": socket.SHUT_RDWR, "time": time, "fcntl": __import__("fcntl"),
     "threading": threading, "socket_mod": socket, "SUPERSEDE_QUIET_S": QUIET, "SUPERSEDE_MAX_S": MAXW}
pf = next(n for n in mod.body if isinstance(n, ast.FunctionDef) and n.name == "_proc_start")
exec(ast.get_source_segment(src, pf), g)
NAMES = ("_ident", "_reg_prefix", "_reg_path", "_reg_read", "_claim", "_newer_session", "_unclaim", "_on_supersede",
         "_superseded_watch", "_reg_lock", "_reg_unlock", "_prev_alive")
M = {}
for name in NAMES:
    fn = next(n for n in cls.body if isinstance(n, ast.FunctionDef) and n.name == name)
    exec(textwrap.dedent(ast.get_source_segment(src, fn)), g)
    M[name] = g[name]
TMP = tempfile.mkdtemp()
g["SESS_DIR"] = os.path.join(TMP, "sess")

MSGS = []
class Rec(logging.Handler):
    def emit(self, r): MSGS.append(r.getMessage())
lg = logging.getLogger("r17"); lg.addHandler(Rec()); lg.setLevel(logging.INFO); lg.propagate = False


class H:
    def __init__(self, ip, user=None, ssl=False, port=8088, uid="U1"):
        self.client_address = (ip, 5000); self.user = types.SimpleNamespace(id=user) if user else None
        self.is_ssl = ssl; self.server = types.SimpleNamespace(server_address=("0.0.0.0", port))
        self.uid = uid; self._claimed = False; self._superseded = False; self.logger = lg; self.request = None
        self._my_start = None; self._last_rx = time.monotonic(); self._closed = False; self.shutdown = False
        self.io_calls = []; self._sup_t = None; self._prev = None
    def _io(self, fn, *a): self.io_calls.append(getattr(fn, "__name__", str(fn))); return True
    def _drop_downlink(self): pass
for name in NAMES:
    setattr(H, name, staticmethod(M[name]) if name in ("_reg_read", "_reg_unlock") else M[name])

signal.alarm(100)  # the whole test: a hang FAILs instead of blocking the check
P = F = 0
def ok(c, m):
    global P, F
    P += bool(c); F += (not c); print(("PASS" if c else "FAIL"), m, flush=True)


class Sess:
    """a forked session: commands claim / newer / unclaim / quit over a pipe; it reports its end ("END ...")"""
    def __init__(self, ip, user=None, ssl=False, port=8088, uid="U1"):
        cr, cw = os.pipe(); rr, rw = os.pipe()
        a, self.b = socket.socketpair()
        self.uid = uid
        self.pid = os.fork()
        if self.pid == 0:
            os.close(cw); os.close(rr); self.b.close(); signal.alarm(40)
            h = H(ip, user, ssl, port, uid); h.request = a
            seen = {}
            def on_usr1(signum, frame):
                e = H._reg_read(h._reg_path(uid))
                seen["entry_first"] = e is not None and e[0] != os.getpid()
                seen["t"] = time.monotonic()
                h._on_supersede(signum, frame)
            signal.signal(signal.SIGUSR1, on_usr1)
            cmd = os.fdopen(cr); n = 0
            def say(x): os.write(rw, (x + "\n").encode())
            while True:
                rd, _, _ = select.select([a, cmd], [], [], 0.2)
                if a in rd:
                    try:
                        d = a.recv(64)
                    except OSError:
                        d = b""
                    if not d:
                        q = time.monotonic() - seen["t"] if "t" in seen else -1
                        say(f"END superseded={h._superseded} entry_first={seen.get('entry_first')} "
                            f"drop={'_drop_downlink' in h.io_calls} chunks={n} after={q:.1f}")
                        break
                    h._last_rx = time.monotonic(); n += 1
                if cmd in rd:
                    c = cmd.readline().strip()
                    if c == "claim":
                        say(f"CLAIM {h._claim(uid)}")
                    elif c == "newer":
                        say(f"NEWER {h._newer_session(uid)}")
                    elif c == "unclaim":
                        h._unclaim(); say("UNCLAIMED")
                    else:
                        break
            h._closed = True; h._unclaim()
            os._exit(0)
        os.close(cr); os.close(rw); a.close()
        self.cw = cw; self.r = os.fdopen(rr)

    def ask(self, c, timeout=5.0):
        os.write(self.cw, (c + "\n").encode())
        return self.read(timeout)

    def read(self, timeout):
        rd, _, _ = select.select([self.r], [], [], timeout)
        return self.r.readline().strip() if rd else None

    def done(self):
        try:
            os.write(self.cw, b"quit\n")
        except OSError:
            pass
        self.b.close(); os.waitpid(self.pid, 0)


def field(o, k):
    return dict(x.split("=", 1) for x in (o or "").split()[1:] if "=" in x).get(k)


def path(uid, ident, port=8088):
    h = H(ident if port == 8088 else "x", user=None if port == 8088 else ident, ssl=port != 8088, port=port, uid=uid)
    return h._reg_path(uid)


# 1. 8088, the same device back from the same address: the previous session stops its downlink at once and ends
#    once quiet for SUPERSEDE_QUIET_S; the new entry was written before the signal
A = Sess("10.41.24.32"); c1 = A.ask("claim"); time.sleep(0.05)
B = Sess("10.41.24.32"); c2 = B.ask("claim")
o = A.read(QUIET + 6)
ok(c1 == "CLAIM True" and c2 == "CLAIM True", f"R17 both sessions claim ({c1}, {c2})")
ok(field(o, "superseded") == "True" and field(o, "drop") == "True", f"R17 8088 same uid + address: previous session superseded, downlink dropped ({o})")
ok(field(o, "entry_first") == "True", "R17 r7 A7-4/B7-4: the newer entry is written before the signal")
ok(o is not None and QUIET - 0.5 <= float(field(o, "after")) <= QUIET + 6, f"R17 r7: the superseded session ended after ~{QUIET} s quiet ({field(o, 'after')} s)")
ok(B.ask("newer") == "NEWER False", "R17 the new session is the newest (its end judges by consumers as before)")
A.done(); B.done()
# 2. the user's decision: uplink still read while it arrives; the end comes only after QUIET without data
A = Sess("10.41.24.32", uid="U2"); A.ask("claim"); time.sleep(0.05)
B = Sess("10.41.24.32", uid="U2"); B.ask("claim")
for i in range(8):           # 4 s of "retransmitted" reports on the old connection, longer than QUIET
    time.sleep(0.5); A.b.send(b"x")
o = A.read(QUIET + 6)
ok(field(o, "chunks") == "8" and float(field(o, "after") or 0) >= 4 + QUIET - 0.6,
   f"R17 r7: a superseded session keeps reading while data arrives (8 reports read) and ends {QUIET} s after the last ({o})")
A.done(); B.done()
# 3. the same uid from ANOTHER address: another device: no signal, both kept; the older one sees a newer session
A = Sess("10.41.24.32", uid="U3"); A.ask("claim"); time.sleep(0.05)
B = Sess("10.41.7.57", uid="U3"); B.ask("claim")
o = A.read(1.5)
ok(o is None, "R17 8088 same uid from another address: previous session kept, not signalled")
ok(A.ask("newer") == "NEWER True" and B.ask("newer") == "NEWER False",
   "R17 the older session's end sees a newer session of the uid (no disconnect); the newer one sees none")
A.done(); B.done()
# 4. 8089: the same OTS user from any address is the same device; another user is not
A = Sess("10.41.24.32", user=7, ssl=True, port=8089, uid="U4"); A.ask("claim"); time.sleep(0.05)
B = Sess("10.41.7.57", user=7, ssl=True, port=8089, uid="U4"); B.ask("claim")
o = A.read(QUIET + 6)
ok(field(o, "superseded") == "True", f"R17 8089 same uid + same OTS user (another address): superseded ({o})")
A.done(); B.done()
A = Sess("10.41.24.32", user=7, ssl=True, port=8089, uid="U5"); A.ask("claim"); time.sleep(0.05)
B = Sess("10.41.24.32", user=8, ssl=True, port=8089, uid="U5"); B.ask("claim")
ok(A.read(1.5) is None, "R17 8089 same uid, another OTS user: not signalled")
A.done(); B.done()
# 5. listeners are separate
A = Sess("10.41.24.32", uid="U6"); A.ask("claim"); time.sleep(0.05)
B = Sess("10.41.24.32", user=7, ssl=True, port=8089, uid="U6"); B.ask("claim")
ok(A.read(1.5) is None, "R17 the 8089 session of a uid does not touch its 8088 session (per listener)")
A.done(); B.done()
# 6. r7 A7-1: an OLDER connection whose report arrives late does not supersede the newer session; it is superseded
#    itself and takes no subscription (_claim -> False)
A = Sess("10.41.24.32", uid="U7"); time.sleep(0.05)      # the older process, not identified yet
B = Sess("10.41.24.32", uid="U7"); cb = B.ask("claim")    # the newer one identifies first
ca = A.ask("claim")
ok(cb == "CLAIM True" and ca == "CLAIM False", f"R17 r7 A7-1: a late older connection gets no subscription ({ca})")
ok(B.read(1.5) is None, "R17 r7 A7-1: ... and does not end the newer session")
o = A.read(QUIET + 6)
ok(field(o, "superseded") == "True", f"R17 r7 A7-1: the late older connection ends once quiet ({o})")
A.done(); B.done()
# 7. dead / reused pids, malformed entries, pid 1
os.makedirs(g["SESS_DIR"], exist_ok=True)
p8 = path("U8", "10.41.24.32")
open(p8, "w").write(f"{os.getpid()} 1 10.41.24.32 -\n")
ok(H._reg_read(p8) is None, "R17 an entry whose pid was reused (start ticks differ) is ignored")
open(p8, "w").write("999999 1 10.41.24.32 -\n")
A = Sess("10.41.24.32", uid="U8"); ca = A.ask("claim")
e = H._reg_read(p8)
ok(ca == "CLAIM True" and e is not None and e[0] == A.pid, "R17 an entry of a dead session is replaced, nothing signalled")
A.done()
p9 = path("U9", "10.41.24.32")
for junk in ("", "garbage", "1 2", "1 x y z"):
    open(p9, "w").write(junk)
    ok(H._reg_read(p9) is None, f"R17 malformed entry {junk!r} is ignored (no signal)")
open(p9, "w").write(f"1 {g['_proc_start'](1)} 10.41.24.32 -\n")
ok(H._reg_read(p9) is None, "R17 pid 1 (the listener) is never a target")
# 8. _unclaim removes only its own entry
A = Sess("10.41.24.32", uid="U10"); A.ask("claim"); A.ask("unclaim")
ok(not os.path.exists(path("U10", "10.41.24.32")), "R17 the end removes its own registry entry")
A.done()
A = Sess("10.41.24.32", uid="U11"); A.ask("claim"); time.sleep(0.05)
B = Sess("10.41.7.57", uid="U11"); B.ask("unclaim")
ok(os.path.exists(path("U11", "10.41.24.32")), "R17 the end never removes another session's entry")
A.done(); B.done()
# 10. r8 A8-1 (the user's decision): the RTO case. A was quiet through the outage (QUIET + 1 s) before B came back;
#     the phone's TCP retransmits on A 1 s after the supersede: A must still be reading (round 7 ended it at once)
A = Sess("10.41.24.32", uid="U13"); A.ask("claim"); time.sleep(QUIET + 1)
B = Sess("10.41.24.32", uid="U13"); B.ask("claim"); time.sleep(1)
sent = 0
for i in range(5):
    try:
        A.b.send(b"r"); sent += 1
    except OSError:
        break
    time.sleep(0.2)
o = A.read(MAXW + 6)
ok(sent == 5 and field(o, "chunks") == "5", f"R17 r8 A8-1: the reports retransmitted after an outage longer than QUIET are read ({o}; sent {sent})")
ok(o is not None and QUIET + 1 <= float(field(o, "after")) <= MAXW + 1, f"R17 r8: the wait covered the outage plus QUIET, bounded by MAX ({field(o, 'after')} s)")
A.done(); B.done()
# 11. r8 A8-4/B8-3: the newer session ends first while the superseded one keeps talking: it ends at MAX after the
#     supersede at the latest (round 7: deaf for as long as the phone talked)
A = Sess("10.41.24.32", uid="U14"); A.ask("claim"); time.sleep(0.05)
B = Sess("10.41.24.32", uid="U14"); B.ask("claim"); time.sleep(0.5)
B.ask("unclaim"); B.done()
t0 = time.monotonic(); o = None
while o is None and time.monotonic() - t0 < MAXW + 6:
    try:
        A.b.send(b"t")
    except OSError:
        pass
    o = A.read(0.5)
ok(o is not None and float(field(o, "after")) <= MAXW + 1.5, f"R17 r8: with no newer session left, a talking superseded session ends at MAX ({o})")
A.done()
# 12. r8 A8-5/B8-4: claims are serialized by the registry lock (a claim waits while it is held)
import fcntl as _f
os.makedirs(g["SESS_DIR"], exist_ok=True)
lk = os.open(os.path.join(g["SESS_DIR"], ".lock"), os.O_RDWR | os.O_CREAT, 0o600); _f.flock(lk, _f.LOCK_EX)
A = Sess("10.41.24.32", uid="U15")
os.write(A.cw, b"claim\n"); t0 = time.monotonic()
early = A.read(0.8)
os.close(lk)
late = A.read(3)
ok(early is None and late == "CLAIM True", f"R17 r8: a claim waits for the registry lock ({early}, then {late})")
A.done()
# 9. registry unusable: logged, subscribe as before (fail-safe), nothing signalled
g["SESS_DIR"] = "/proc/forbidden/sess"
h = H("10.41.24.32", uid="U12"); r = h._claim("U12")
ok(r is True and not h._claimed and any("registry" in m and "unusable" in m for m in MSGS), "R17 registry unusable: logged, subscribed as before R17")
print("ALL PASS" if F == 0 else "SOME FAILED (%d)" % F)

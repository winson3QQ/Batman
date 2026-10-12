"""Offline regression for R17 (review r6 A6-2/A6-4/B6-6): one live session per device and listener.
Extracts _proc_start and the registry methods verbatim (ast) from the overlay and drives them with real processes:
a forked "previous session" that installs the overlay's _on_supersede for SIGUSR1 and reports what it saw."""
import ast, sys, textwrap, logging, os, signal, socket, tempfile, time, types, hashlib

src = open(sys.argv[1], encoding="utf-8").read()
mod = ast.parse(src)
cls = next(n for n in mod.body if isinstance(n, ast.ClassDef) and n.name == "EudHandler")
g = {"os": os, "signal": signal, "hashlib": hashlib, "SHUT_RDWR": socket.SHUT_RDWR, "time": time}
pf = next(n for n in mod.body if isinstance(n, ast.FunctionDef) and n.name == "_proc_start")
exec(ast.get_source_segment(src, pf), g)
for name in ("_reg_path", "_reg_read", "_claim", "_newer_session", "_unclaim", "_on_supersede"):
    fn = next(n for n in cls.body if isinstance(n, ast.FunctionDef) and n.name == name)
    exec(textwrap.dedent(ast.get_source_segment(src, fn)), g)
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
for name in ("_reg_path", "_reg_read", "_claim", "_newer_session", "_unclaim", "_on_supersede"):
    setattr(H, name, g[name])

signal.alarm(60)  # the whole test: a hang FAILs instead of blocking the check
P = F = 0
def ok(c, m):
    global P, F
    P += bool(c); F += (not c); print(("PASS" if c else "FAIL"), m)


def previous(ip, user=None, ssl=False, port=8088, uid="U1"):
    """fork a 'previous session': it claims uid, installs _on_supersede, blocks in recv; reports via a pipe"""
    r, w = os.pipe()
    a, b = socket.socketpair()
    pid = os.fork()
    if pid == 0:
        os.close(r); b.close()
        signal.alarm(20)  # never outlive the test
        h = H(ip, user, ssl, port, uid); h.request = a
        signal.signal(signal.SIGUSR1, h._on_supersede)
        h._claim(uid)
        os.write(w, b"claimed\n")
        got = a.recv(10)  # returns b"" once _on_supersede shut the socket
        os.write(w, (f"recv={got!r} superseded={h._superseded}\n").encode())
        h._unclaim()
        os._exit(0)
    os.close(w); a.close()
    f = os.fdopen(r)
    assert f.readline().strip() == "claimed"
    return pid, f, b


def outcome(pid, f, timeout=3.0):
    """what the previous session saw, or None if it is still blocked"""
    import select
    rd, _, _ = select.select([f], [], [], timeout)
    if not rd:
        return None
    line = f.readline().strip()
    os.waitpid(pid, 0)
    return line


def stop(pid, f, b):
    b.close()
    outcome(pid, f, 3.0)


# 1. 8088, the same device comes back from the same address: the previous session is ended, no disconnect is due
pid, f, b = previous("10.41.24.32")
h = H("10.41.24.32"); h._claim("U1")
o = outcome(pid, f)
ok(o == "recv=b'' superseded=True" and h._claimed, f"R17 8088 same uid + same address: previous session ended by SIGUSR1 ({o})")
ok(not h._newer_session("U1"), "R17 the new session is the newest (its end will judge by consumers as before)")
# 2. 8088, the same uid from ANOTHER address: nothing ended, the registry keeps the previous session
pid, f, b = previous("10.41.24.32", uid="U2")
h = H("10.41.7.57", uid="U2"); h._claim("U2")
o = outcome(pid, f, 1.0)
ok(o is None and not h._claimed and any("both kept" in m for m in MSGS), "R17 8088 same uid from another address: previous session kept, no signal")
# the previous one is still the registered one; for IT a newer session does not exist; for the other one it does
ok(h._newer_session("U2"), "R17 another live session holds the uid: the other one's end sends no disconnect")
stop(pid, f, b)
# 3. 8089, the same OTS user: ended; another user: kept
pid, f, b = previous("10.41.24.32", user=7, ssl=True, port=8089, uid="U3")
h = H("10.41.7.57", user=7, ssl=True, port=8089, uid="U3"); h._claim("U3")
o = outcome(pid, f)
ok(o == "recv=b'' superseded=True", f"R17 8089 same uid + same OTS user (any address): previous session ended ({o})")
pid, f, b = previous("10.41.24.32", user=7, ssl=True, port=8089, uid="U4")
h = H("10.41.24.32", user=8, ssl=True, port=8089, uid="U4"); h._claim("U4")
o = outcome(pid, f, 1.0)
ok(o is None and not h._claimed, "R17 8089 same uid, another OTS user: previous session kept, no signal")
stop(pid, f, b)
# 4. listeners are separate: an 8089 claim never touches the 8088 session of the same uid
pid, f, b = previous("10.41.24.32", uid="U5")
h = H("10.41.24.32", user=7, ssl=True, port=8089, uid="U5"); h._claim("U5")
o = outcome(pid, f, 1.0)
ok(o is None and h._claimed, "R17 the 8089 session of a uid does not end its 8088 session (per listener)")
stop(pid, f, b)
# 5. a dead previous session and a reused pid are ignored
h = H("10.41.24.32", uid="U6")
os.makedirs(g["SESS_DIR"], exist_ok=True)
open(h._reg_path("U6"), "w").write(f"{os.getpid()} 1 10.41.24.32 -\n")  # our pid, wrong start time = reused pid
ok(h._reg_read("U6") is None, "R17 a registry entry whose pid was reused (start time differs) is ignored")
open(h._reg_path("U6"), "w").write("999999 1 10.41.24.32 -\n")
h._claim("U6")
ok(h._claimed and h._reg_read("U6")[0] == os.getpid(), "R17 an entry of a dead session is replaced, nothing signalled")
for junk in ("", "garbage", "1 2", "1 x y z"):
    open(h._reg_path("U7"), "w").write(junk)
    ok(h._reg_read("U7") is None, f"R17 malformed entry {junk!r} is ignored (fail-safe: no signal)")
open(h._reg_path("U7"), "w").write(f"1 {g['_proc_start'](1)} 10.41.24.32 -\n")
ok(h._reg_read("U7") is None, "R17 pid 1 (the listener) is never a target")
# 6. _unclaim removes only its own entry
h = H("10.41.24.32", uid="U8"); h._claim("U8"); h._unclaim()
ok(not os.path.exists(h._reg_path("U8")), "R17 the end removes its own registry entry")
pid, f, b = previous("10.41.24.32", uid="U9")
h = H("10.41.24.32", uid="U9"); h._claimed = True; h._unclaim()
ok(os.path.exists(h._reg_path("U9")), "R17 the end never removes another session's entry")
stop(pid, f, b)
# 7. registry unusable: logged, nothing signalled, the session goes on
g["SESS_DIR"] = "/proc/forbidden/sess"
h = H("10.41.24.32", uid="U10"); h._claim("U10")
ok(not h._claimed and any("registry" in m and "unusable" in m for m in MSGS), "R17 registry unusable: logged, previous session left to R6")
print("ALL PASS" if F == 0 else "SOME FAILED (%d)" % F)

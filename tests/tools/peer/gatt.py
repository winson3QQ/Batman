"""gatt — prov-gatt-254's cases on the air (docs: the prov-gatt-254 design, §5). `peer.py gatt <case> …` runs ONE case
on ONE connection and only OBSERVES: the verdict is scripts/dv/prov-gatt-254.sh's, from these lines plus 04's btmon
(gattjudge.py). Output, key=value only (no bare hex that could be mistaken for a frame line):

  PIDS wsl=<n> win=<n>
  GATTR case=<id> conn=<ok|err:<why>> target=<addr> mtu=<n|unk> wmax=<n> frame=<n> status0=<ok|att:<x>|-> hs=<real|fake|none>
        warm=<0|1> sent=<frames> answered=<k>/<n> lost=<yes|no> lost_at=<before-close|-> msg2len=<n> nlen=<a,b,c/d>
        order=<ok|bad|-> resp_frames=<n> status1=<ok|att:<x>|-> skip=<-|why>
  GATTEND case=<id> rc=<n>

Frames are flags(1) ‖ seq(2 BE) ‖ data (provd/frame.go). Every Q case cuts a REAL `info` ciphertext c so that exactly
one Reassembler rule is broken and END lands on the last frame: a provd without that rule reassembles c, decrypts it
and ANSWERS (answered=1 -> the judge's FAIL); the correct provd drops the link (answered=0). After the warm-up (msg1 in
one frame, one `info` in one frame) the Reassembler's `next` is 1 (frame.go:44-47), which Q3 aims at.

`python gatt.py --selftest`: every case against a fake node that runs a Reassembler per rule variant (strict = provd's
rules; one lax variant per Q rule): strict must give the PASS-shaped observation, each lax variant the FAIL-shaped
one — the negative controls of the Q class.
"""
import os
import sys
import threading
import time

import cbor2

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "vectors", "219-protocol"))

import nodecert  # noqa: E402
import peer_core  # noqa: E402
import transport_sock as ts  # noqa: E402

ACCEPT = {"m1", "s1a", "s3b", "s512a", "s8192", "t1", "t2", "t4", "b1", "b1x"}
REJECT = {"q1", "q2", "q3", "q4", "q5", "q6", "q7a", "q7b", "s512b", "s8193"}
CASES = ACCEPT | REJECT
OBSERVE_S = 8.0


class Rec:
    """Wraps a transport's recv: the length of every frame the node sent, grouped by message (END flag)."""

    def __init__(self, t):
        self.t, self.msgs, self.cur = t, [], []
        self._recv = t.recv
        t.recv = self.recv

    def recv(self, timeout=10.0):
        f = self._recv(timeout)
        self.cur.append(len(f))
        if f and f[0] & 2:
            self.msgs.append(self.cur)
            self.cur = []
        return f

    def nlen(self):
        return "/".join(",".join(str(x) for x in m) for m in self.msgs) or "-"


def env_of_len(p, ct_len):
    """An `info` envelope whose ciphertext is exactly ct_len bytes (body key 99 padding; provd ignores it,
    session.go:654-655)."""
    target = ct_len - 16
    base = len(p.envelope("info"))
    p.id -= 1
    for k in range(max(0, target - base - 8), target + 8):
        raw = p.envelope("info", {99: b"\0" * k})
        if len(raw) == target:
            return raw
        p.id -= 1
    raise ValueError("no padding gives a %d B ciphertext" % ct_len)


def frames_for(case, c, p):
    """The frame sequence of a case, from the ciphertext c (§5.2 table)."""
    k, m = max(1, len(c) // 3), max(2, 2 * len(c) // 3)
    H = lambda fl, sq, d=b"": bytes([fl]) + sq.to_bytes(2, "big") + d  # noqa: E731
    return {
        "q1": [H(1, 0, c[:k]), H(2, 2, c[k:])],                   # seq 1 skipped
        "q2": [H(3, 1, c)],                                       # start with seq 1
        "q3": [H(2, 1, c)],                                       # continuation without start, seq = stale next 1
        "q4": [H(1, 0, c[:k]), H(0, 1, c[k:m]), H(2, 1, c[m:])],  # seq 1 twice
        "q5": [H(1, 0, c[:k]), H(3, 0, c)],                       # start while assembling
        "q6": [H(7, 0, c)],                                       # reserved flag bit 0x04
        "t1": [H(1, 0, c[:k]), H(2, 1, c[k:])],                   # twins: the same bytes, headers right
        "t2": [H(3, 0, c)],
        "t4": [H(1, 0, c[:k]), H(0, 1, c[k:m]), H(2, 2, c[m:])],
        "s3b": [H(1, 0, c), H(2, 1)],                             # a 3 B (header only) end frame
    }[case]


def observe(p, secs):
    """(answered, lost) within secs: a complete response that decrypts, or the link gone."""
    end = time.monotonic() + secs
    while True:
        left = end - time.monotonic()
        if left <= 0:
            return 0, False
        try:
            m = p.recv_msg(timeout=left)
        except TimeoutError:
            return 0, False
        except ts.Closed:
            return 0, True
        except ValueError:          # the node's own frames broke our reassembler: say so, never a verdict
            return -1, False
        try:
            cbor2.loads(p.noise.decrypt(m))
            return 1, False
        except Exception:  # noqa: BLE001 — not a response of this session
            return -1, False


def held(t, secs):
    """True when the link is still there after secs (no LOST line meanwhile)."""
    end = time.monotonic() + secs
    while time.monotonic() < end:
        try:
            line = t.q.get(timeout=max(0.05, end - time.monotonic()))
        except Exception:  # noqa: BLE001 — queue.Empty
            continue
        if line is None or line.startswith("LOST ") or line.startswith("WATCHDOG"):
            return False
        if line.startswith("N ") or line.startswith("NT "):
            t._pending.append(line)
    return True


class Case:
    def __init__(self, a, t, out=print, pinned_dac=None, e_priv=None):
        self.a, self.t, self.out = a, t, out
        self.pinned_dac, self.e_priv = pinned_dac, e_priv
        self.r = dict(case=a.case, conn="ok", target="-", mtu="unk", wmax="0", frame="0", status0="-", hs="none",
                      warm="0", sent="0", answered="0/0", lost="no", lost_at="-", msg2len="0", nlen="-", order="-",
                      resp_frames="0", status1="-", skip="-")

    def line(self):
        keys = ["case", "conn", "target", "mtu", "wmax", "frame", "status0", "hs", "warm", "sent", "answered", "lost",
                "lost_at", "msg2len", "nlen", "order", "resp_frames", "status1", "skip"]
        return "GATTR " + " ".join("%s=%s" % (k, str(self.r[k]).replace(" ", "_")) for k in keys)

    def status(self):
        try:
            self.t.read("STATUS")
            return "ok"
        except Exception as e:  # noqa: BLE001 — BridgeError("ERR read <exc>") or a lost link
            s = str(e)
            for code in ("0x0e", "0x05", "0x0f", "0x0E", "0x0F"):
                if code in s:
                    return "att:" + code.lower()
            return "att:" + (s.split()[-1] if s else "unknown")

    def connect(self):
        """Scan, connect (the pinned address when given), STATUS, CTRL -> frame size. Returns True when connected."""
        t, a = self.t, self.a
        devs = sorted(t.scan(4 if a.addr != "-" else 8), key=lambda d: -d[1])
        cands = [d for d, _r in devs if a.addr in ("-", d)]
        if not cands:
            self.r["conn"] = "err:not-seen"
            return False
        for addr in cands:
            try:
                line = t.connect(addr)
            except Exception as e:  # noqa: BLE001
                self.r["conn"] = "err:" + str(e).split()[-1]
                continue
            for kv in line.split()[2:]:
                k, _, v = kv.partition("=")
                if k in ("wmax", "mtu"):
                    self.r[k] = v
            self.r["status0"] = self.status()
            try:
                ctrl = cbor2.loads(t.read("CTRL"))
            except Exception as e:  # noqa: BLE001
                self.r["conn"] = "err:ctrl-" + str(e).split()[-1]
                t.close_link()
                continue
            t.set_frame(int(ctrl.get(3, 244)))
            self.r["frame"] = t.frame_limit
            self.addr = addr
            self.r["target"] = addr
            self.r["conn"] = "ok"
            return True
        return False

    def handshake(self, frame):
        p = peer_core.Peer(self.t, frame=frame)
        self.t.mark_msg1()
        try:
            ok = p.handshake(None, self.a.device_id, e_priv=self.e_priv)
        except TimeoutError:
            self.r["hs"] = "none"
            return None
        except ts.Closed:
            self.r["hs"] = "none"
            self.r["lost"], self.r["lost_at"] = "yes", "before-close"
            return None
        self.r["msg2len"] = len(p.msg2)
        if not ok:
            self.r["hs"] = "fake"
            return None
        try:
            if self.pinned_dac is not None:
                nodecert.identify(p.cert, p.rs, self.pinned_dac)
            else:
                nodecert.first_contact(p.cert, p.rs, self.a.device_id)
        except nodecert.NotTarget:
            self.r["hs"], self.r["conn"] = "real", "err:wrong-target"
            return None
        self.r["hs"] = "real"
        p.frame = self.t.frame_limit
        return p

    def warm(self, p):
        try:
            st, _b = p.request("info", timeout=10)
        except (TimeoutError, ts.Closed):
            return False
        self.r["warm"] = "1" if st == 0 else "0"
        return st == 0

    def send_frames(self, fs):
        for f in fs:
            self.t.send(f)
        self.r["sent"] = len(fs)

    def run(self):
        a = self.a
        if not self.connect():
            return 1
        rec = Rec(self.t)
        self._rec = rec
        frame = 4 if a.case == "s1a" else self.t.frame_limit
        p = self.handshake(frame)
        self.r["nlen"] = rec.nlen()
        if p is None:
            return self.finish(0)
        if a.case == "s1a":
            p.frame = 4
            try:
                st, _b = p.request("info", timeout=20)
                self.r["answered"] = "%d/1" % (1 if st == 0 else 0)
            except (TimeoutError, ts.Closed) as e:
                self.r["answered"] = "0/1"
                if isinstance(e, ts.Closed):
                    self.r["lost"], self.r["lost_at"] = "yes", "before-close"
            self.r["nlen"] = rec.nlen()
            return self.finish(0)
        if not self.warm(p):
            self.r["nlen"] = rec.nlen()
            return self.finish(0)
        if a.case == "m1":
            self.r["answered"] = "1/1"
        elif a.case in ("b1", "b1x"):
            self.pipeline(p, a.n or (100 if a.case == "b1" else 1000))
        elif a.case in ("q7a", "q7b"):
            self.send_frames([b"\x01"] if a.case == "q7a" else [b"\x03\x00"])
            ans, lost = observe(p, OBSERVE_S)
            self.r["answered"] = "0/0"
            if lost:
                self.r["lost"], self.r["lost_at"] = "yes", "before-close"
        else:
            if a.case.startswith("s512"):
                self.t.cmd("FRAMEMAX 513")
                n = int(self.t.expect(("FRAMESIZE",)).split()[1])
                self.r["frame"] = n
                self.t.frame_limit = n
                if n < 513:
                    self.r["skip"] = "wmax-%s" % self.r["wmax"]
                    return self.finish(0)
                raw = env_of_len(p, 509 if a.case == "s512a" else 510)
                c = p.noise.encrypt(raw)
                fs = [bytes([3, 0, 0]) + c]
            elif a.case in ("s8192", "s8193"):
                raw = env_of_len(p, 8192 if a.case == "s8192" else 8193)
                c = p.noise.encrypt(raw)
                fs = ts.split(c, self.t.frame_limit)
            else:
                c = p.noise.encrypt(p.envelope("info"))
                fs = frames_for(a.case, c, p)
            self.send_frames(fs)
            ans, lost = observe(p, OBSERVE_S if a.case in REJECT else 20.0)
            self.r["answered"] = "%d/1" % max(ans, 0)
            if ans < 0:
                self.r["skip"] = "unreadable-reply"
            if lost:
                self.r["lost"], self.r["lost_at"] = "yes", "before-close"
            elif a.case in ACCEPT and ans == 1 and not held(self.t, OBSERVE_S):
                self.r["lost"], self.r["lost_at"] = "yes", "before-close"
        self.r["nlen"] = rec.nlen()
        return self.finish(0)

    def pipeline(self, p, n):
        """n `info` requests sent back to back (each one frame), then n responses read: ids in order, then one more."""
        ids, got = [], []
        try:
            for _ in range(n):
                raw = p.envelope("info")
                ids.append(p.id)
                p.send_env(raw)
            self.r["sent"] = n
            for _ in range(n):
                got.append(p.recv_env(timeout=30).get(1))
            st, _b = p.request("info", timeout=15)
            self.r["answered"] = "%d/%d" % (len(got) + (1 if st == 0 else 0), n + 1)
            self.r["order"] = "ok" if got == ids else "bad"
        except Exception as e:  # noqa: BLE001 — a lost / undecryptable response is an observation
            self.r["answered"] = "%d/%d" % (len(got), n + 1)
            self.r["order"] = "bad"
            if isinstance(e, ts.Closed):
                self.r["lost"], self.r["lost_at"] = "yes", "before-close"
        # frames per response: msgs[0] = msg2, [1] = the warm-up's response, [2] = the first pipelined one
        rf = self._rec.msgs[2:3]
        self.r["resp_frames"] = len(rf[0]) if rf else 0

    def finish(self, rc):
        if self.r["lost"] != "yes" and self.r["conn"] == "ok":
            self.r["status1"] = self.status()
        try:
            self.t.close_link()
        except Exception:  # noqa: BLE001
            pass
        self.out(self.line())
        return rc


def main(a, transport_cls, out=print):
    if a.case not in CASES:
        out("GATTEND case=%s rc=2" % a.case)
        return 2
    deadline = a.deadline or (600 if a.case == "b1x" else 120)
    parent = os.getppid()
    t = transport_cls()
    t.start_hb(alive=lambda: os.getppid() == parent)
    rc = [1]

    def guard():
        # the hard limit and the parent watch (review A3-m5): either one ends the case; the bridge's watchdog then
        # cuts the link within its WATCHDOG_S once HBs stop
        end = time.monotonic() + deadline
        while time.monotonic() < end:
            if os.getppid() != parent:
                break
            time.sleep(1)
        out("GATTEND case=%s rc=124" % a.case)
        sys.stdout.flush()
        try:
            t.quit()
        finally:
            os._exit(124)
    threading.Thread(target=guard, daemon=True).start()
    try:
        out("PIDS wsl=%d win=%d" % (os.getpid(), t.pid()))
        rc[0] = Case(a, t, out).run()
    finally:
        t.quit()
    out("GATTEND case=%s rc=%d" % (a.case, rc[0]))
    return rc[0]


# ---- selftest: a fake node behind a fake bridge --------------------------------------------------------------------

class LaxReassembler(ts.Reassembler):
    """provd's Reassembler (frame.go:31-58, incl. MaxFrame 512) with ONE rule switched off or changed — the products the
    Q / S cases must FAIL. variant: strict | noseq | start_next_seq | noactive | restart | noreserved | nolen | le3 |
    nomaxframe | nomaxmsg"""

    def __init__(self, variant):
        super().__init__(8192 if variant != "nomaxmsg" else 1 << 20)
        self.v = variant

    def push(self, f):
        v = self.v
        if v == "nolen" and len(f) < 3:
            raise RuntimeError("panic: slice bounds out of range")     # f[3:] with len < 3: provd would crash
        if (len(f) < 3 and v != "nolen") or (v == "le3" and len(f) <= 3):
            raise ValueError("frame")
        if len(f) > 512 and v != "nomaxframe":
            raise ValueError("frame")
        flags = f[0] & 3 if v == "noreserved" else f[0]
        if flags & ~3:
            raise ValueError("frame")
        seq, data = int.from_bytes(f[1:3], "big"), f[3:]
        if flags & 1:
            if self.active and v != "restart":
                raise ValueError("start")
            if seq != 0 and v != "start_next_seq":
                raise ValueError("start")
            self.buf, self.next, self.active = b"", (seq if v == "start_next_seq" else 0), True
        elif not self.active:
            if v != "noactive":
                raise ValueError("no start")
            self.active = True
        if seq != self.next and v != "noseq":
            raise ValueError("seq")
        self.next += 1
        self.buf += data
        if len(self.buf) > self.max:
            raise ValueError("too long")
        if flags & 2:
            m, self.buf, self.active = self.buf, b"", False
            return m
        return None


class FakeNode:
    """The bridge's line protocol in front of a node: NX responder with the vectors' node static key and node_cert,
    `info` answered, a framing violation -> LOST (provd's Close -> Device1.Disconnect); a crash -> LOST + crashed."""

    def __init__(self, variant="strict", wmax=514, bluez_drop=False):
        import queue
        import verify
        from noise.connection import Keypair, NoiseConnection
        v = verify.load_vectors()
        K = v["keys"]
        self.NC, self.KP = NoiseConnection, Keypair
        self.s_priv, self.cert = bytes.fromhex(K["s_node_priv"]), bytes.fromhex(v["node_cert"]["cbor"])
        self.device_id = K["device_id"]
        self.dac = bytes.fromhex(K["dac_cert_der"])
        self.variant, self.wmax, self.bluez_drop = variant, wmax, bluez_drop
        self.lines = queue.Queue()
        self.stdout = iter(self.lines.get, None)
        self.crashed, self.lost, self.writes = False, False, []
        me = self

        class In:
            def write(self, s):
                for ln in s.splitlines():
                    me.on(ln.strip())

            def flush(self):
                pass

            def close(self):
                me.lines.put(None)
        self.stdin = In()
        self._reset()

    def _reset(self):
        self.r = LaxReassembler(self.variant)
        self.nc = None
        self.frame = 244

    def wait(self, timeout=None):
        return 0

    def terminate(self):
        pass

    def put(self, s):
        self.lines.put(s + "\n")

    def notify(self, msg):
        for f in ts.split(msg, min(244, self.frame)):
            self.put("N " + f.hex())

    def on(self, c):
        if c.startswith("SCAN"):
            self.put("DEV AA:04 -50")
            self.put("SCAN-END 1")
        elif c.startswith("CONNECT"):
            self._reset()
            self.lost = False
            self.put("CONNECTED AA:04 wmax=%d mtu=517" % self.wmax)
        elif c == "READ CTRL":
            self.put("VAL a4010102000318f404192000")
        elif c == "READ STATUS":
            self.put("VAL a10300")
        elif c.startswith("FRAMEMAX"):
            self.frame = min(int(c.split()[1]), self.wmax, 513)
            self.put("FRAMESIZE %d" % self.frame)
        elif c.startswith("FRAME"):
            self.put("FRAMESIZE %d" % min(244, int(c.split()[1]), self.wmax))
        elif c == "PID":
            self.put("PID 4242")
        elif c in ("MSG1", "HB", "TS on"):
            pass
        elif c.startswith("W "):
            if self.lost:
                return
            f = bytes.fromhex(c[2:])
            self.writes.append(f)
            if self.bluez_drop and len(f) > 512:
                return            # bluetoothd: check_length refuses a value > 512 B, silently for a Write Command
            try:
                m = self.r.push(f)
            except ValueError:
                self.lost = True
                self.put("LOST AA:04")
                return
            except RuntimeError:
                self.crashed, self.lost = True, True
                self.put("LOST AA:04")
                return
            if m is not None:
                self.message(m)
        elif c == "CLOSE":
            self.put("CLOSED AA:04 sent_after_msg1=%d" % len(self.writes))

    def message(self, m):
        if self.nc is None:
            nc = self.NC.from_name(peer_core.NX)
            nc.set_as_responder()
            nc.set_prologue(peer_core.prologue(self.device_id))
            nc.set_keypair_from_private_bytes(self.KP.STATIC, self.s_priv)
            nc.start_handshake()
            try:
                nc.read_message(m)
            except Exception:  # noqa: BLE001
                self.lost = True
                self.put("LOST AA:04")
                return
            self.nc = nc
            self.notify(nc.write_message(self.cert))
            return
        try:
            env = cbor2.loads(self.nc.decrypt(m))
        except Exception:  # noqa: BLE001 — AEAD failure: provd ends the session (session.go:324-329)
            self.lost = True
            self.put("LOST AA:04")
            return
        import verify
        self.notify(self.nc.encrypt(verify.det_dumps({1: env.get(1), 3: {}, 4: 0})))


class _A:
    def __init__(self, case, device_id, n=0):
        self.case, self.device_id, self.addr, self.n, self.deadline = case, device_id, "-", n, 0


def _observe(case, variant, n=0, wmax=514):
    """Run one case against FakeNode(variant); returns (GATTR fields dict, node)."""
    import peer
    node = FakeNode(variant, wmax)
    t = peer.BleTransport(popen=node)
    lines = []
    a = _A(case, node.device_id, n)
    Case(a, t, out=lines.append, pinned_dac=node.dac).run()
    t.quit()
    g = [ln for ln in lines if ln.startswith("GATTR ")]
    d = dict(kv.split("=", 1) for kv in g[-1].split()[1:]) if g else {}
    return d, node


def selftest():
    import gattjudge
    fails, n = [], 0

    def check(name, cond, info=""):
        nonlocal n
        n += 1
        print(("ok   " if cond else "FAIL ") + name)
        if not cond:
            fails.append("%s  [%s]" % (name, info))

    old = OBSERVE_S
    globals()["OBSERVE_S"] = 1.0       # the fake node answers at once; 1 s is plenty and keeps the selftest short
    try:
        # strict node: every case gives the shape the judge PASSes (accept: answered, link held; reject: dropped)
        for case in sorted(CASES - {"b1x"}):
            d, node = _observe(case, "strict", n=20 if case == "b1" else 0)
            v = gattjudge.peer_shape(case, d, crashed=node.crashed)
            check("strict provd, %s: %s" % (case, v), v == "PASS", d)
        # the Q-class negative controls: each lax Reassembler must make its case FAIL (the review's B-B1 / A-M2)
        lax = {"q1": "noseq", "q2": "start_next_seq", "q3": "noactive", "q4": "noseq", "q5": "restart",
               "q6": "noreserved", "q7a": "nolen", "q7b": "nolen", "s3b": "le3", "s512b": "nomaxframe",
               "s8193": "nomaxmsg"}
        for case, var in sorted(lax.items()):
            d, node = _observe(case, var)
            v = gattjudge.peer_shape(case, d, crashed=node.crashed)
            check("lax provd (%s) must FAIL %s: %s" % (var, case, v), v == "FAIL", d)
        # the Q2 trap (review A2-m1 / B2-m2): removing only frame.go:37's seq!=0 is NOT enough to accept 03 0001 c —
        # :40 resets next and :44 still drops it; so that variant must NOT be the one the Q2 negative control uses
        class Only37(LaxReassembler):
            def push(self, f):
                flags, seq = f[0], int.from_bytes(f[1:3], "big")
                if flags & 1 and not self.active:
                    self.buf, self.next, self.active = b"", 0, True      # :37 gone, :40 kept
                    if seq != self.next:                                  # :44
                        raise ValueError("seq")
                    self.next += 1
                    self.buf += f[3:]
                    if flags & 2:
                        m, self.buf, self.active = self.buf, b"", False
                        return m
                    return None
                return LaxReassembler.push(self, f)
        import peer
        node = FakeNode("strict")
        node.r = Only37("strict")
        orig = FakeNode._reset
        FakeNode._reset = lambda self: (setattr(self, "nc", None), setattr(self, "frame", 244),
                                        setattr(self, "r", Only37("strict")))
        try:
            t = peer.BleTransport(popen=node)
            out = []
            Case(_A("q2", node.device_id), t, out=out.append, pinned_dac=node.dac).run()
            t.quit()
        finally:
            FakeNode._reset = orig
        d = dict(kv.split("=", 1) for kv in [x for x in out if x.startswith("GATTR")][-1].split()[1:])
        check("only frame.go:37 removed still drops Q2 (so Q2's lax variant is 'start sets next = seq')",
              gattjudge.peer_shape("q2", d, crashed=False) == "PASS", d)
        # run 1 (2026-11-26): BlueZ itself drops the 513 B value (shared/gatt-server.c:807-818, 871-873) -> NA, not FAIL
        import peer
        node = FakeNode("strict", bluez_drop=True)
        t = peer.BleTransport(popen=node)
        out = []
        Case(_A("s512b", node.device_id), t, out=out.append, pinned_dac=node.dac).run()
        t.quit()
        d = dict(kv.split("=", 1) for kv in [x for x in out if x.startswith("GATTR")][-1].split()[1:])
        check("s512b behind a bluetoothd that drops > 512 B: link held, nothing answered -> NA (the capture decides)",
              gattjudge.peer_shape("s512b", d) == "NA", d)
        # S512 on a central whose wmax < 513: skipped, never a verdict
        d, _node = _observe("s512a", "strict", wmax=244)
        check("S512 with wmax 244 -> skip (N/A), not PASS", gattjudge.peer_shape("s512a", d) == "NA", d)
        # B1: strict answers all in order; a node that drops one notification frame makes answered < n
        d, _node = _observe("b1", "strict", n=30)
        check("B1 strict: 31/31 in order", d.get("answered") == "31/31" and d.get("order") == "ok", d)
        node = FakeNode("strict")
        drop = {"k": 0}
        on0 = node.notify

        def lossy(msg):
            drop["k"] += 1
            if drop["k"] == 10:          # the 10th notified message never reaches the central
                return
            on0(msg)
        node.notify = lossy
        t = peer.BleTransport(popen=node)
        out = []
        a = _A("b1", node.device_id, 30)
        Case(a, t, out=out.append, pinned_dac=node.dac).run()
        t.quit()
        d = dict(kv.split("=", 1) for kv in [x for x in out if x.startswith("GATTR")][-1].split()[1:])
        check("B1 negative: one lost notification -> not all answered / order bad -> FAIL",
              gattjudge.peer_shape("b1", d) == "FAIL", d)
    finally:
        globals()["OBSERVE_S"] = old
    for f in fails:
        print("FAIL gatt selftest:", f)
    print("gatt selftest: %d checks, %d failed" % (n, len(fails)))
    return 1 if fails else 0


if __name__ == "__main__":
    if sys.argv[1:2] == ["--selftest"]:
        sys.exit(selftest())
    print(__doc__)
    sys.exit(2)

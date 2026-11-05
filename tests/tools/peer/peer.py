#!/usr/bin/env python3
"""peer.py — the harness's provisioning-app stand-in (docs/design/254-h4-harness.md §4.1, §4.2). Runs in WSL from the
venv ~/.batman-dv/peer-venv; the Noise session, the keys and every verdict stay on this side.

Transports (--via):
  ble   the Windows bridge blebridge.py, started through WSL interop with the absolute Windows python path
  sock  provclient's frame-socket proxy over ssh (prov_test provd with SOCK_ONLY=1)
  (http through the phone relay comes with the HTTP units; P3 provides the endpoint)

Every connection is identified by the node_cert of its OWN handshake (nodecert.identify / first_contact) before any
request is sent; a connection that is not the target is closed and the next candidate is tried.

Output: one JSON line per step, secrets only as short() (owner.short).

Subcommands so far:
  eh9 --device-id <hex18>      read-only probe on a legacy / unclaimed node (E-H9): connect, NX with the device_id
                               prologue, first_contact (dev DAC rule), `info`, a ~9 KiB `info` (unknown body key,
                               ignored by the node: multi-frame both ways), idle --hold seconds, `info` again
  --selftest                   the BLE transport against a fake bridge (no Bluetooth)
"""
import argparse
import json
import os
import pathlib
import queue
import subprocess
import sys
import threading
import time

import cbor2

HERE = pathlib.Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parents[1] / "vectors" / "219-protocol"))

import nodecert  # noqa: E402
import peer_core  # noqa: E402
import transport_sock as ts  # noqa: E402

WIN_PY = "/mnt/c/Users/yello/AppData/Local/Programs/Python/Python313/python.exe"
BRIDGE_WIN = r"\\wsl.localhost\Ubuntu-24.04" + str(HERE / "blebridge.py").replace("/", "\\")


def out(**kw):
    print(json.dumps(kw, sort_keys=True), flush=True)


class BridgeError(Exception):
    pass


class BleTransport:
    """The peer_core transport interface (send / recv / frame_limit) over the bridge's line protocol."""

    def __init__(self, argv=None, popen=None):
        # -E but not -s: bleak is pinned in the user site (requirements-win.txt is installed with --user)
        self.p = popen or subprocess.Popen(argv or [WIN_PY, "-E", BRIDGE_WIN], stdin=subprocess.PIPE,
                                           stdout=subprocess.PIPE, text=True, bufsize=1)
        self.q = queue.Queue()
        self.frame_limit = ts.MAX_FRAME
        self.msg1_frames = 0
        self._pending = []          # N lines that arrived while a control reply was awaited
        threading.Thread(target=self._reader, daemon=True).start()

    def _reader(self):
        for line in self.p.stdout:
            self.q.put(line.rstrip("\n"))
        self.q.put(None)

    def cmd(self, line):
        try:
            self.p.stdin.write(line + "\n")
            self.p.stdin.flush()
        except (BrokenPipeError, OSError) as e:
            raise ts.Closed(str(e)) from None

    def expect(self, prefixes, timeout=30.0):
        """Next control line starting with one of prefixes; N lines that arrive meanwhile are kept for recv()."""
        end = time.monotonic() + timeout
        while True:
            left = end - time.monotonic()
            if left <= 0:
                raise TimeoutError("bridge: no %s in %.0fs" % (prefixes, timeout))
            try:
                line = self.q.get(timeout=left)
            except queue.Empty:
                continue
            if line is None:
                raise ts.Closed("bridge exited")
            if line.startswith("N "):
                self._pending.append(line)
                continue
            if line.startswith("LOST "):
                raise ts.Closed(line)
            if any(line.startswith(p) for p in prefixes) or line.startswith("ERR "):
                return line

    def scan(self, secs=8):
        self.cmd("SCAN %d" % secs)
        devs = []
        while True:
            line = self.expect(("DEV ", "SCAN-END"), timeout=secs + 20)
            if line.startswith("SCAN-END"):
                return devs
            _, a, r = line.split()
            devs.append((a, int(r)))

    def connect(self, addr):
        self._pending = []
        self.cmd("CONNECT " + addr)
        line = self.expect(("CONNECTED", "ERR connect"), timeout=40)
        if line.startswith("ERR"):
            raise BridgeError(line)
        return line

    def read(self, which):
        self.cmd("READ " + which)
        line = self.expect(("VAL ", "ERR read"))
        if line.startswith("ERR"):
            raise BridgeError(line)
        return bytes.fromhex(line.split()[1])

    def set_frame(self, n):
        self.cmd("FRAME %d" % n)
        self.frame_limit = int(self.expect(("FRAMESIZE",)).split()[1])

    def mark_msg1(self):
        self.cmd("MSG1")

    def send(self, pkt):
        if len(pkt) > self.frame_limit:
            raise ValueError("frame %d > %d" % (len(pkt), self.frame_limit))
        self.cmd("W " + pkt.hex())

    def recv(self, timeout=10.0):
        if self._pending:
            return bytes.fromhex(self._pending.pop(0)[2:])
        end = time.monotonic() + timeout
        while True:
            left = end - time.monotonic()
            if left <= 0:
                raise TimeoutError("no frame in %.1fs" % timeout)
            try:
                line = self.q.get(timeout=left)
            except queue.Empty:
                continue
            if line is None:
                raise ts.Closed("bridge exited")
            if line.startswith("N "):
                return bytes.fromhex(line[2:])
            if line.startswith("LOST ") or line.startswith("ERR write"):
                raise ts.Closed(line)

    def close_link(self):
        self.cmd("CLOSE")
        try:
            line = self.expect(("CLOSED",), timeout=15)
        except ts.Closed as e:                 # the link was already lost (LOST): nothing to count
            return -1 if "LOST" in str(e) else -2
        try:
            return int(line.rsplit("=", 1)[1])
        except (IndexError, ValueError):
            return -1

    def quit(self):
        try:
            self.p.stdin.close()
        except OSError:
            pass
        try:
            self.p.wait(timeout=10)
        except subprocess.TimeoutExpired:
            self.p.terminate()


def open_target(t, device_id, pinned_dac=None, scan_secs=8, log=out, e_priv=None):
    """Scan, then try candidates strongest first until a handshake's node_cert is the target.
    pinned_dac None = first contact (unclaimed / legacy): the dev-DAC rule + the device_id read over ssh.
    Returns (peer, addr, dac_der). Never sends a request on a connection that is not the target."""
    devs = sorted(t.scan(scan_secs), key=lambda d: -d[1])
    log(step="scan", candidates=len(devs))
    for addr, rssi in devs:
        try:
            t.connect(addr)
        except BridgeError as e:
            log(step="connect", addr=addr, rssi=rssi, result=str(e))
            continue
        ctrl = cbor2.loads(t.read("CTRL"))
        t.set_frame(int(ctrl.get(3, 244)))
        p = peer_core.Peer(t, frame=t.frame_limit)
        t.mark_msg1()
        ok = p.handshake(None, device_id, e_priv=e_priv)
        t.msg1_frames = len(ts.split(b"\0" * 32, t.frame_limit))
        if not ok:
            log(step="handshake", addr=addr, rssi=rssi, result="fake")
            t.close_link()
            continue
        try:
            dac = nodecert.first_contact(p.cert, p.rs, device_id) if pinned_dac is None else pinned_dac
            nodecert.identify(p.cert, p.rs, dac)
        except nodecert.NotTarget as e:
            sent = t.close_link() - t.msg1_frames
            log(step="identify", addr=addr, rssi=rssi, result="wrong-target", why=str(e), sent_after_msg1=sent)
            continue
        log(step="identify", addr=addr, rssi=rssi, result="ok", device_id=device_id, frame=t.frame_limit)
        return p, addr, dac
    raise nodecert.NotTarget("no candidate is the target")


def cmd_eh9(a):
    t = BleTransport()
    try:
        p, addr, dac = open_target(t, a.device_id)
        st, body = p.request("info")
        out(step="info", status=st, state=body.get(7) if isinstance(body, dict) else None,
            device_id=body.get(1) if isinstance(body, dict) else None)
        # one message just under max_msg - 16 (CTRL key 4 = 8192): many frames each way, no app-level chunking
        # (a 9000 B message would need §5.1 chunks; unchunked, provd drops the link — seen on 04, 2026-11-03)
        big = {99: b"\0" * 7800}
        t0 = time.monotonic()
        st2, body2 = p.request("info", big, timeout=30)
        out(step="info-9k", status=st2, request_bytes=len(p.last_env), frames=-(-len(p.last_env) // (t.frame_limit - 3)),
            seconds=round(time.monotonic() - t0, 2))
        # provd closes an ANONYMOUS session idle >= 30 s (IdleAnon, server.go:29; authed 300 s; never while a request
        # is in flight, session.go:121, 284-288): 25 s idle must keep it, a further 40 s idle must not
        for hold, want in ((25, "open"), (40, "closed")):
            time.sleep(hold)
            try:
                st3, _ = p.request("info", timeout=15)
                got = "open" if st3 == 0 else "error"
            except (ts.Closed, TimeoutError) as e:
                got = "closed"
            out(step="idle", seconds=hold, expect=want, got=got, ok=(got == want))
        out(step="close", sent_after_msg1=t.close_link())
        out(step="dac", dac_sha256_16=__import__("hashlib").sha256(dac).hexdigest()[:16])
        return 0
    finally:
        t.quit()


def selftest():
    """The BLE transport + open_target against a fake bridge that plays the vectors' node (no Bluetooth)."""
    import verify
    v = verify.load_vectors()
    K = v["keys"]
    msg2 = bytes.fromhex(v["noise_nx"]["msg2"])
    fails, n = [], 0

    def check(name, cond):
        nonlocal n
        n += 1
        if not cond:
            fails.append(name)

    class FakePopen:
        """Two advertisers: AA:02 answers with a node_cert of another DAC (wrong target), AA:04 with the vectors'."""

        def __init__(self):
            self.lines = queue.Queue()
            self.stdout = iter(self.lines.get, None)
            me = self

            class In:
                def write(self, s):
                    me.on(s.strip())

                def flush(self):
                    pass

                def close(self):
                    me.lines.put(None)
            self.stdin = In()
            self.cur, self.sent = None, 0

        def wait(self, timeout=None):
            return 0

        def on(self, c):
            if c.startswith("SCAN"):
                self.lines.put("DEV AA:02 -50\n")
                self.lines.put("DEV AA:04 -70\n")
                self.lines.put("SCAN-END 2\n")
            elif c.startswith("CONNECT"):
                self.cur, self.sent = c.split()[1], 0
                self.lines.put("CONNECTED %s wmax=514 mtu=517\n" % self.cur)
            elif c == "READ CTRL":
                self.lines.put("VAL a4010102000318f404192000\n")
            elif c.startswith("FRAME"):
                self.lines.put("FRAMESIZE 244\n")
            elif c == "MSG1":
                self.sent = 0
            elif c.startswith("W "):
                self.sent += 1
                if self.sent == 1:          # msg1 done (one frame): answer msg2
                    for f in ts.split(msg2, 244):
                        self.lines.put("N %s\n" % f.hex())
            elif c == "CLOSE":
                self.lines.put("CLOSED %s sent_after_msg1=%d\n" % (self.cur, self.sent))

    logs = []
    eph = bytes.fromhex(K["phone_ephemeral_priv"])      # the vector msg2 opens only with the vector's ephemeral
    t = BleTransport(popen=FakePopen())
    # both candidates carry the vectors' node_cert: pinning a DAC it does not carry makes each a wrong target
    try:
        open_target(t, K["device_id"], pinned_dac=bytes.fromhex(v["identity_file"]["dev_cert_der"]), scan_secs=0,
                    log=lambda **kw: logs.append(kw), e_priv=eph)
        check("negative: no candidate matches a foreign pinned DAC -> NotTarget", False)
    except nodecert.NotTarget:
        check("negative: no candidate matches a foreign pinned DAC -> NotTarget", True)
    wrong = [l for l in logs if l.get("result") == "wrong-target"]
    check("both candidates were rejected by the node_cert check (not by a failed handshake)", len(wrong) == 2
          and not any(l.get("result") == "fake" for l in logs))
    check("nothing beyond msg1 was sent on a wrong target", all(l.get("sent_after_msg1") == 0 for l in wrong))
    logs.clear()
    t = BleTransport(popen=FakePopen())
    p, addr, dac = open_target(t, K["device_id"], pinned_dac=bytes.fromhex(K["dac_cert_der"]), scan_secs=0,
                               log=lambda **kw: logs.append(kw), e_priv=eph)
    check("the pinned target is found (strongest-first order tried AA:02 first)", addr == "AA:02")
    check("frame size from CTRL / FRAMESIZE", t.frame_limit == 244)
    for x in fails:
        print("FAIL peer selftest:", x)
    print("peer.py selftest: %d checks, %d failed" % (n, len(fails)))
    return 1 if fails else 0


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--selftest", action="store_true")
    sub = ap.add_subparsers(dest="cmd")
    e = sub.add_parser("eh9")
    e.add_argument("--device-id", required=True)
    e.add_argument("--hold", type=int, default=230)
    a = ap.parse_args()
    if a.selftest:
        # the vectors layer (selftest.py: peer_core / owner byte for byte against gen.py) first — it had no caller
        # before 2026-11-03, so nothing ran it — then the BLE transport against the fake bridge
        import selftest as vectors_selftest
        r1 = vectors_selftest.run()
        r2 = selftest()
        return 1 if (r1 or r2) else 0
    if a.cmd == "eh9":
        return cmd_eh9(a)
    ap.print_help()
    return 2


if __name__ == "__main__":
    sys.exit(main())

"""Frame-socket transport for peer.py (docs/design/254-h23-harness.md §4.8.2): one SOCK_SEQPACKET packet = one GATT
frame (flags ‖ seq ‖ data); control packets 0xC0 (read CTRL) / 0xC1 (read STATUS), length 1, only before the
handshake; the reply is the same byte + the CBOR value, or 0xC2 ‖ ATT error code when the node has no fresh value.

Two ways to reach provd's gatt.sock (provd:provd 0700, prov_test only):
  * Sock(path)       — directly (CI, or anything already running as uid 471);
  * Proxy(argv)      — a subprocess speaking one hex line per packet on stdin / stdout, e.g.
                       ssh root@node provclient sock-as 471 -- proxy /tmp/run/batman-provd-test/gatt.sock
"""
import select
import socket
import subprocess

CTL_CTRL, CTL_STATUS, CTL_ERROR = 0xC0, 0xC1, 0xC2
MAX_FRAME = 244


class Closed(Exception):
    """The node closed the connection (BLE: the link dropped)."""


class Sock:
    def __init__(self, path, timeout=10.0):
        self.s = socket.socket(socket.AF_UNIX, socket.SOCK_SEQPACKET)
        self.s.settimeout(timeout)
        self.s.connect(path)
        self.frame_limit = MAX_FRAME

    def send(self, pkt: bytes):
        self.s.send(pkt)

    def recv(self, timeout=10.0) -> bytes:
        self.s.settimeout(timeout)
        try:
            b = self.s.recv(4096)
        except socket.timeout:
            raise TimeoutError("no packet in %.1fs" % timeout) from None
        except OSError as e:
            raise Closed(str(e)) from None
        if not b:
            raise Closed("EOF")
        return b

    def closed_within(self, t) -> bool:
        """True when the node closes the connection within t seconds (no data expected meanwhile)."""
        r, _, _ = select.select([self.s], [], [], t)
        if not r:
            return False
        try:
            return self.s.recv(4096) == b""
        except OSError:
            return True

    def close(self):
        self.s.close()


class Proxy:
    """argv = a command whose stdin / stdout carry one packet per line, hex (provclient proxy)."""

    def __init__(self, argv, timeout=10.0):
        self.p = subprocess.Popen(argv, stdin=subprocess.PIPE, stdout=subprocess.PIPE, bufsize=0)
        self.frame_limit = MAX_FRAME
        self._buf = b""

    def send(self, pkt: bytes):
        try:
            self.p.stdin.write(pkt.hex().encode() + b"\n")
            self.p.stdin.flush()
        except (BrokenPipeError, OSError) as e:
            raise Closed(str(e)) from None

    def _line(self, timeout):
        while b"\n" not in self._buf:
            r, _, _ = select.select([self.p.stdout], [], [], timeout)
            if not r:
                raise TimeoutError("no packet in %.1fs" % timeout)
            chunk = self.p.stdout.read1(65536) if hasattr(self.p.stdout, "read1") else self.p.stdout.read(1)
            if not chunk:
                raise Closed("proxy EOF")
            self._buf += chunk
        line, self._buf = self._buf.split(b"\n", 1)
        return line.strip()

    def recv(self, timeout=10.0) -> bytes:
        line = self._line(timeout)
        if not line:
            raise Closed("EOF")
        return bytes.fromhex(line.decode())

    def closed_within(self, t) -> bool:
        try:
            self._line(t)
            return False
        except TimeoutError:
            return False
        except Closed:
            return True

    def close(self):
        try:
            self.p.stdin.close()
        except OSError:
            pass
        try:
            self.p.wait(timeout=5)
        except subprocess.TimeoutExpired:
            self.p.terminate()


def split(msg: bytes, limit: int):
    """flags(1) ‖ seq(2 BE) ‖ data; seq from 0 per message (219 §4.1)."""
    per = max(1, limit - 3)
    out, seq, off = [], 0, 0
    while True:
        end = min(off + per, len(msg))
        flags = (1 if off == 0 else 0) | (2 if end == len(msg) else 0)
        out.append(bytes([flags]) + seq.to_bytes(2, "big") + msg[off:end])
        seq += 1
        off = end
        if end == len(msg):
            return out


class Reassembler:
    def __init__(self, max_msg=8192):
        self.buf, self.next, self.active, self.max = b"", 0, False, max_msg

    def push(self, f: bytes):
        """Returns the message when complete, None otherwise; raises ValueError on a framing violation."""
        if len(f) < 3 or f[0] & ~3:
            raise ValueError("frame")
        flags, seq, data = f[0], int.from_bytes(f[1:3], "big"), f[3:]
        if flags & 1:
            if self.active or seq != 0:
                raise ValueError("start")
            self.buf, self.next, self.active = b"", 0, True
        elif not self.active:
            raise ValueError("no start")
        if seq != self.next:
            raise ValueError("seq")
        self.next += 1
        self.buf += data
        if len(self.buf) > self.max:
            raise ValueError("too long")
        if flags & 2:
            m, self.buf, self.active = self.buf, b"", False
            return m
        return None

"""httprelay — the phone half of peer.py's HTTP transport (docs/design/254-h4-harness.md §4.3). Runs on the S20 under
Termux with the Python standard library only; started by the host over ssh, one run at a time:

    python -I httprelay.py <node-ip> <port>

It talks to ONE address — the one in argv — and never anything else; it only moves bytes (the bodies are Noise
ciphertext) and decides nothing. One line per message on stdin / stdout:

  -> REQ <id> <METHOD> <path> <headers-json-hex> <body-hex>
  <- RSP <id> <status> <body-hex> <keep|close> <hdr-hex>     (hdr = JSON of the X-Batman-* response headers, or -)
  -> PUT-FILE <id> <path> <local-file> <headers-json-hex>        (the upload body is a file already on the phone)
  <- RSP <id> <status> <body-hex> <keep|close> <hdr-hex>
  -> RESET                                                        (drop the kept connection; the next REQ opens one)
  <- ERR <id> refused|timeout|unreach|reset|closed|proto          (the host's verdicts never rest on these alone:
                                                                    the node-side capture is the evidence, §4.3)
The connection is persistent (HTTP/1.1 keep-alive, no "Connection: close"), so the host can see whether the NODE
closed it (the fake-path FIN check, §4.2). Paths must start with "/" and must not carry a scheme or a host.
"""
import errno
import http.client
import json
import os
import socket
import sys

CONNECT_TIMEOUT = 10.0
READ_TIMEOUT = 30.0
UPLOAD_TIMEOUT = 900.0


def classify(e):
    if isinstance(e, ConnectionRefusedError):
        return "refused"
    if isinstance(e, (socket.timeout, TimeoutError)):
        return "timeout"
    if isinstance(e, ConnectionResetError):
        return "reset"
    if isinstance(e, (http.client.RemoteDisconnected, http.client.BadStatusLine, BrokenPipeError)):
        return "closed"
    if isinstance(e, OSError) and e.errno in (errno.EHOSTUNREACH, errno.ENETUNREACH):
        return "unreach"
    return "proto"


class Relay:
    def __init__(self, host, port, out):
        self.host, self.port, self.out = host, port, out
        self.conn = None

    def say(self, line):
        self.out.write(line + "\n")
        self.out.flush()

    def _conn(self, timeout):
        if self.conn is None:
            self.conn = http.client.HTTPConnection(self.host, self.port, timeout=CONNECT_TIMEOUT)
            self.conn.connect()
        self.conn.sock.settimeout(timeout)
        return self.conn

    def _send(self, rid, method, path, headers, body, timeout):
        if not path.startswith("/") or "://" in path or path.startswith("//"):
            self.say("ERR %s proto" % rid)
            return
        headers = {k: v for k, v in headers.items() if k.lower() not in ("host", "connection")}
        try:
            c = self._conn(timeout)
            c.request(method, path, body=body, headers=headers)
            r = c.getresponse()
            data = r.read()
            keep = "close" if r.will_close else "keep"
            xh = {k: v for k, v in r.getheaders() if k.lower().startswith("x-batman-")}
            if r.will_close:
                self.reset()
            self.say("RSP %s %d %s %s %s" % (rid, r.status, data.hex() or "-", keep,
                                             json.dumps(xh, sort_keys=True).encode().hex() if xh else "-"))
        except Exception as e:  # noqa: BLE001 — every failure is a classified line, never a crash
            self.reset()
            self.say("ERR %s %s" % (rid, classify(e)))

    def reset(self):
        if self.conn is not None:
            try:
                self.conn.close()
            except Exception:  # noqa: BLE001
                pass
        self.conn = None

    def handle(self, line):
        p = line.split()
        if not p:
            return
        try:
            if p[0] == "REQ" and len(p) == 6:
                hdr = json.loads(bytes.fromhex(p[4]).decode()) if p[4] != "-" else {}
                body = bytes.fromhex(p[5]) if p[5] != "-" else None
                self._send(p[1], p[2], p[3], hdr, body, READ_TIMEOUT)
            elif p[0] == "PUT-FILE" and len(p) == 5:
                hdr = json.loads(bytes.fromhex(p[4]).decode()) if p[4] != "-" else {}
                hdr["Content-Length"] = str(os.path.getsize(p[3]))
                with open(p[3], "rb") as f:
                    self._send(p[1], "PUT", p[2], hdr, f, UPLOAD_TIMEOUT)
            elif p[0] == "RESET":
                self.reset()
                self.say("RESET-DONE")
            else:
                self.say("ERR %s proto" % (p[1] if len(p) > 1 else "-"))
        except (ValueError, OSError):
            self.say("ERR %s proto" % (p[1] if len(p) > 1 else "-"))


def main(argv):
    if len(argv) != 3 or not argv[2].isdigit():
        sys.stderr.write("usage: httprelay.py <node-ip> <port>\n")
        return 2
    r = Relay(argv[1], int(argv[2]), sys.stdout)
    for line in sys.stdin:
        r.handle(line.strip())
    r.reset()
    return 0


# ---- selftest: against a local server (no phone, no node) ----

def selftest():
    import http.server
    import io
    import tempfile
    import threading

    class H(http.server.BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.1"

        def log_message(self, *a):
            pass

        def do_POST(self):
            n = int(self.headers.get("Content-Length", 0))
            body = self.rfile.read(n)
            if self.path == "/close":           # the node's fake path: answer, then close the connection
                self.send_response(200)
                self.send_header("Content-Length", str(len(body)))
                self.send_header("Connection", "close")
                self.end_headers()
                self.wfile.write(body)
                self.close_connection = True
                return
            self.send_response(200)
            self.send_header("Content-Length", str(len(body)))
            if self.path == "/batman/v1/session":
                self.send_header("X-Batman-Session", "c2Vzc2lvbi1pZC10ZXN0")
            self.end_headers()
            self.wfile.write(body[::-1])

        def do_PUT(self):
            n = int(self.headers.get("Content-Length", 0))
            self.rfile.read(n)
            out = str(n).encode()
            self.send_response(200)
            self.send_header("Content-Length", str(len(out)))
            self.end_headers()
            self.wfile.write(out)

    srv = http.server.ThreadingHTTPServer(("127.0.0.1", 0), H)
    port = srv.server_address[1]
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    silent = socket.socket()                  # accepts, never answers: a request on it times out
    silent.bind(("127.0.0.1", 0))
    silent.listen(1)
    dead = socket.socket()                    # a port nobody listens on: refused
    dead.bind(("127.0.0.1", 0))
    dead_port = dead.getsockname()[1]
    dead.close()

    out = io.StringIO()
    r = Relay("127.0.0.1", port, out)
    r.handle("REQ 1 POST /batman/v1/msg - " + b"abc".hex())
    r.handle("REQ 2 POST /batman/v1/session - " + b"xyz".hex())
    r.handle("REQ 3 POST http://evil.example/x - 00")
    r.handle("REQ 4 POST /close - " + b"q".hex())
    with tempfile.NamedTemporaryFile(delete=False) as f:
        f.write(b"\0" * 100000)
    r.handle("PUT-FILE 5 /batman/v1/bulk/0 %s -" % f.name)
    os.unlink(f.name)
    global READ_TIMEOUT
    old = READ_TIMEOUT
    READ_TIMEOUT = 1.0
    Relay("127.0.0.1", silent.getsockname()[1], out).handle("REQ 6 POST /batman/v1/msg - 00")
    READ_TIMEOUT = old
    Relay("127.0.0.1", dead_port, out).handle("REQ 7 POST /batman/v1/msg - 00")
    r.handle("BOGUS 8")
    srv.shutdown()
    lines = out.getvalue().splitlines()
    fails, n = [], 0

    def check(name, cond):
        nonlocal n
        n += 1
        if not cond:
            fails.append("%s  (output: %s)" % (name, lines))

    check("REQ relays the body and the response", "RSP 1 200 %s keep -" % b"cba".hex() in lines)
    sh = json.dumps({"X-Batman-Session": "c2Vzc2lvbi1pZC10ZXN0"}).encode().hex()
    check("the connection is kept and X-Batman-Session is relayed", "RSP 2 200 %s keep %s" % (b"zyx".hex(), sh) in lines)
    check("a path with a scheme / host is refused (one address only)", "ERR 3 proto" in lines)
    check("the server closing after its response is reported as close", "RSP 4 200 %s close -" % b"q".hex() in lines)
    check("PUT-FILE sends the whole file with Content-Length", "RSP 5 200 %s keep -" % b"100000".hex() in lines)
    check("a silent peer -> timeout", "ERR 6 timeout" in lines)
    check("nobody listening -> refused", "ERR 7 refused" in lines)
    check("unknown command -> proto", "ERR 8 proto" in lines)
    check("negative: refused and timeout are told apart", "ERR 6 refused" not in lines and "ERR 7 timeout" not in lines)
    silent.close()
    for x in fails:
        print("FAIL httprelay selftest:", x)
    print("httprelay selftest: %d checks, %d failed" % (n, len(fails)))
    return 1 if fails else 0


if __name__ == "__main__":
    sys.exit(selftest() if sys.argv[1:2] == ["--selftest"] else main(sys.argv))

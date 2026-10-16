"""End-to-end over REAL loopback sockets: a throw-away CA, mTLS on a free port, sqlite, a fake AMQP
channel. Identification -> row -> publish; ping -> pong; supersede; ownership refusals; presence at end."""
import asyncio
import datetime as dt
import os
import socket
import ssl
import subprocess
import time

import pytest
from sqlalchemy import text

from batman_eud_gateway import amqp, config
from batman_eud_gateway.server import Gateway
from batman_eud_gateway.tls import TlsContextHolder
from tests.test_amqp import FakeChannel, FakeConn

pytestmark = pytest.mark.skipif(subprocess.run(["which", "openssl"], capture_output=True).returncode != 0,
                                reason="openssl needed")


def free_port():
    s = socket.socket(); s.bind(("127.0.0.1", 0)); p = s.getsockname()[1]; s.close(); return p


@pytest.fixture(scope="module")
def pki(tmp_path_factory):
    d = tmp_path_factory.mktemp("pki")
    def sh(*a): subprocess.run(a, check=True, capture_output=True, cwd=d)
    sh("openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes", "-keyout", "ca.key", "-out", "ca.pem",
       "-days", "30", "-subj", "/CN=TestCA")
    sh("openssl", "req", "-newkey", "rsa:2048", "-nodes", "-keyout", "server.key", "-out", "server.csr", "-subj", "/CN=server")
    sh("openssl", "x509", "-req", "-in", "server.csr", "-CA", "ca.pem", "-CAkey", "ca.key", "-CAcreateserial",
       "-out", "server.pem", "-days", "30")
    for cn in ("alice", "bob", "carol", "nobody"):
        sh("openssl", "req", "-newkey", "rsa:2048", "-nodes", "-keyout", f"{cn}.key", "-out", f"{cn}.csr", "-subj", f"/CN={cn}")
        sh("openssl", "x509", "-req", "-in", f"{cn}.csr", "-CA", "ca.pem", "-CAkey", "ca.key", "-CAcreateserial",
           "-out", f"{cn}.pem", "-days", "30")
    return d


class Stack:
    def __init__(self, db, pki, settings):
        self.loop = asyncio.new_event_loop()
        asyncio.set_event_loop(self.loop)
        self.db = db
        self.broker = amqp.Broker(self.loop, "h", "u", "p", "1000")
        self.broker.conn = FakeConn()
        self.ch = FakeChannel()
        self.tls = TlsContextHolder(str(pki / "ca.pem"), str(pki / "server.pem"), str(pki / "server.key"), str(pki / "none.crl"))
        self.tls.build()
        self.gw = Gateway(self.loop, settings, db, self.broker, lambda: True, self.tls)
        self.gw.bind_host = "127.0.0.1"
        self.loop.run_until_complete(self.gw.start_listeners())
        self.broker._on_pub_open(self.ch)
        self.port = settings.tls_port

    def run(self, coro_or_secs):
        if isinstance(coro_or_secs, (int, float)):
            self.loop.run_until_complete(asyncio.sleep(coro_or_secs))
        else:
            return self.loop.run_until_complete(coro_or_secs)

    def client(self, pki, cn):
        ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
        ctx.check_hostname = False
        ctx.verify_mode = ssl.CERT_REQUIRED
        ctx.load_verify_locations(str(pki / "ca.pem"))
        ctx.load_cert_chain(str(pki / f"{cn}.pem"), str(pki / f"{cn}.key"))
        async def connect():
            r, w = await asyncio.open_connection("127.0.0.1", self.port, ssl=ctx, ssl_handshake_timeout=5)
            return r, w
        return self.run(connect())

    def close(self):
        self.gw.stop_accepting()
        self.run(0.05)
        for t in asyncio.all_tasks(self.loop):
            t.cancel()
        self.run(0.05)
        self.loop.close()


def sa(uid, callsign="ALPHA"):
    return (f'<event version="2.0" uid="{uid}" type="a-f-G-U-C" how="h-e" time="2026-10-14T01:00:00.000Z" '
            f'start="2026-10-14T01:00:00.000Z" stale="2026-10-14T01:10:00.000Z"><point lat="1" lon="2" hae="0" ce="1" le="1"/>'
            f'<detail><takv device="Pixel" os="34" platform="ATAK-CIV" version="5.1"/><contact callsign="{callsign}"/>'
            f'</detail></event>').encode()


@pytest.fixture
def stack(db, pki):
    s = config.load({"GATEWAY_MAX_CONNS_PER_DEVICE": "2", "GATEWAY_SUPERSEDE_QUIET_S": "1", "GATEWAY_SUPERSEDE_MAX_S": "2"})
    s = config.dataclasses.replace(s, tls_port=free_port(), health_port=free_port())
    st = Stack(db, pki, s)
    yield st
    st.close()


def test_identify_publish_pong_and_end(stack, db, pki):
    r, w = stack.client(pki, "alice")
    w.write(sa("ANDROID-A1")); stack.run(0.3)
    # the row exists before the first publish; the SA was published to cot_parser + firehose
    row = db.eud("ANDROID-A1")
    assert row is not None and row["user_id"] == 1 and row["last_status"] == "Connected"
    pubs = [(e, m) for e, b, m in stack.ch.published]
    assert ("cot_parser", True) in pubs and ("firehose", False) in pubs and ("flask-socketio", False) in pubs
    # ping -> pong
    w.write(b'<event version="2.0" uid="ANDROID-A1-ping" type="t-x-c-t" time="x" start="x" stale="x"/>')
    stack.run(0.2)
    data = stack.run(asyncio.wait_for(r.read(4096), 1))
    assert b"t-x-c-t-r" in data
    dev = next(iter(stack.gw.table.devices.values()))
    assert dev.uid == "ANDROID-A1" and dev.channel is not None and ("dms", "ANDROID-A1", "ANDROID-A1") in dev.channel.needed
    # end: presence Disconnected + a t-x-d-d published
    w.close(); stack.run(0.3)
    assert db.eud("ANDROID-A1")["last_status"] == "Disconnected"
    assert any(b"t-x-d-d" in b for e, b, m in stack.ch.published if e == "cot_parser")
    assert stack.gw.table.devices == {}


def test_supersede_and_draining_deadline(stack, db, pki):
    r1, w1 = stack.client(pki, "alice"); w1.write(sa("ANDROID-S1")); stack.run(0.3)
    r2, w2 = stack.client(pki, "alice"); w2.write(sa("ANDROID-S1")); stack.run(0.3)
    dev = next(iter(stack.gw.table.devices.values()))
    assert dev.current.cid != dev.draining[0].cid and len(dev.draining) == 1
    # a report on the OLD connection is still read and published
    n = len(stack.ch.published)
    w1.write(sa("ANDROID-S1")); stack.run(0.3)
    assert len(stack.ch.published) > n
    # downlink goes to the current socket only
    dev.enqueue(b'<event uid="x" type="b-t-f"><detail/></event>', None, None); stack.run(0.2)
    got2 = stack.run(asyncio.wait_for(r2.read(4096), 1))
    assert b'uid="x"' in got2
    # the superseded one is closed by its deadline (quiet 1 s, max 2 s)
    for _ in range(30):
        stack.gw.tick(time.monotonic()); stack.run(0.1)
        if not dev.draining:
            break
    assert dev.draining == [] and dev.current is not None
    w2.close(); stack.run(0.3)


def test_ownership_refusals(stack, db, pki):
    # alice owns ANDROID-O1
    r, w = stack.client(pki, "alice"); w.write(sa("ANDROID-O1")); stack.run(0.3)
    assert db.eud("ANDROID-O1")["user_id"] == 1
    # bob claims it -> closed, nothing written
    rb, wb = stack.client(pki, "bob"); wb.write(sa("ANDROID-O1")); stack.run(0.3)
    assert stack.run(asyncio.wait_for(rb.read(10), 1)) == b""      # EOF
    assert db.eud("ANDROID-O1")["user_id"] == 1
    assert stack.gw.stats["refusals"] >= 1
    # an unowned row WITH history is refused; without history it is adopted
    with db.engine.begin() as c:
        c.execute(text("INSERT INTO euds (uid, last_status) VALUES ('ANDROID-H1', 'Disconnected'), ('ANDROID-H2', 'Disconnected')"))
        c.execute(text("INSERT INTO cot (sender_uid) VALUES ('ANDROID-H1')"))
    rh, wh = stack.client(pki, "bob"); wh.write(sa("ANDROID-H1", "H1")); stack.run(0.3)
    assert stack.run(asyncio.wait_for(rh.read(10), 1)) == b"" and db.eud("ANDROID-H1")["user_id"] is None
    ra, wa = stack.client(pki, "bob"); wa.write(sa("ANDROID-H2", "H2")); stack.run(0.3)
    assert db.eud("ANDROID-H2")["user_id"] == 2
    # inactive user (carol) and unknown CN: closed before any identification
    rc, wc = stack.client(pki, "carol"); wc.write(sa("ANDROID-C1")); stack.run(0.3)
    assert stack.run(asyncio.wait_for(rc.read(10), 1)) == b"" and db.eud("ANDROID-C1") is None
    rn, wn = stack.client(pki, "nobody"); wn.write(sa("ANDROID-N1")); stack.run(0.3)
    assert stack.run(asyncio.wait_for(rn.read(10), 1)) == b"" and db.eud("ANDROID-N1") is None
    for x in (w, wa):
        x.close()
    stack.run(0.3)


def test_oversize_discarded_session_kept(stack, db, pki):
    r, w = stack.client(pki, "alice"); w.write(sa("ANDROID-B1")); stack.run(0.3)
    big = sa("ANDROID-B1").replace(b"<detail>", b"<detail><remarks>" + b"x" * 70000 + b"</remarks>")
    w.write(big); stack.run(0.5)
    w.write(b'<event version="2.0" uid="ANDROID-B1-ping" type="t-x-c-t" time="x" start="x" stale="x"/>'); stack.run(0.3)
    assert b"t-x-c-t-r" in stack.run(asyncio.wait_for(r.read(4096), 2))
    assert stack.gw.stats["oversize"] == 1
    w.close(); stack.run(0.2)

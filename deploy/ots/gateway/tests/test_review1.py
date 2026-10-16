"""Regression tests for code-review round 1 (C1A/C1B): each FAILS on 9ef088e and PASSES after the fixes."""
import asyncio
import socket
import time
import types

import pytest
from sqlalchemy import text

from batman_eud_gateway import amqp, config
from tests.test_amqp import FakeChannel, FakeConn
from tests.test_integration import Stack, free_port, sa, pki  # noqa: F401  (pki fixture)


@pytest.fixture
def stack(db, pki):
    s = config.load({"GATEWAY_MAX_CONNS_PER_DEVICE": "2", "GATEWAY_SUPERSEDE_QUIET_S": "1", "GATEWAY_SUPERSEDE_MAX_S": "2",
                     "GATEWAY_MAX_PENDING": "8", "GATEWAY_UPLINK_MSGS_PER_S": "5"})
    s = config.dataclasses.replace(s, tls_port=free_port(), health_port=free_port())
    st = Stack(db, pki, s)
    yield st
    st.close()


def test_pre_tls_sockets_are_in_the_pending_pool(stack):
    """C1A-5 / C1B-3: raw sockets that never start TLS count against MAX_PENDING and are evicted oldest-first."""
    raws = []
    for i in range(12):
        s = socket.create_connection(("127.0.0.1", stack.port)); raws.append(s)
        stack.run(0.05)
    assert len(stack.gw.table.pending) <= 8 and stack.gw.table.stats["evicted_pending"] >= 4
    # the oldest ones were aborted: reading them gives EOF/RST
    dead = 0
    for s in raws[:4]:
        s.settimeout(1)
        try:
            if s.recv(10) == b"":
                dead += 1
        except OSError:
            dead += 1
    assert dead == 4
    for s in raws:
        s.close()


def test_writer_follows_the_current_socket_under_backpressure(stack, db, pki):
    """C1A-2 / C1B-1: the old socket is paused (pause_writing); a supersede must move the writer to the new one."""
    r1, w1 = stack.client(pki, "alice"); w1.write(sa("ANDROID-W1")); stack.run(0.3)
    dev = next(iter(stack.gw.table.devices.values()))
    p1 = stack.gw.conns[dev.current.cid]
    p1.pause_writing()                                  # as asyncio does when the old phone stops reading
    dev.enqueue(b'<event uid="m1" type="b-t-f"><detail/></event>', None, None); stack.run(0.2)
    r2, w2 = stack.client(pki, "alice"); w2.write(sa("ANDROID-W1")); stack.run(0.3)
    assert dev.current.cid != p1.conn.cid
    dev.enqueue(b'<event uid="m2" type="b-t-f"><detail/></event>', None, None); stack.run(0.3)
    got = stack.run(asyncio.wait_for(r2.read(4096), 1))
    assert b'uid="m1"' in got or b'uid="m2"' in got        # the NEW socket receives downlink
    w1.close(); w2.close(); stack.run(0.2)


def test_connection_dying_during_identification_leaves_no_ghost(stack, db, pki, monkeypatch):
    """C1A-1: the socket dies while identify awaits the DB -> no device left in the table."""
    orig = stack.gw.db_call

    async def slow(fn, *a, **kw):
        if fn.__name__ == "eud":
            await asyncio.sleep(0.6)
        return await orig(fn, *a, **kw)
    monkeypatch.setattr(stack.gw, "db_call", slow)
    r, w = stack.client(pki, "alice"); w.write(sa("ANDROID-G1")); stack.run(0.3)
    w.transport.abort(); stack.run(1.0)
    assert stack.gw.table.devices == {} and stack.gw.table.pending == {}
    assert db.eud("ANDROID-G1") is None or db.eud("ANDROID-G1")["last_status"] == "Disconnected"


def test_forced_close_is_an_abort(stack, db, pki):
    """C1B-2: a deadline/refusal close must take effect at once, not wait for TCP_USER_TIMEOUT."""
    r, w = stack.client(pki, "alice"); w.write(sa("ANDROID-C1")); stack.run(0.3)
    dev = next(iter(stack.gw.table.devices.values()))
    proto = stack.gw.conns[dev.current.cid]
    proto.close("test"); stack.run(0.2)
    assert proto.conn.closed and stack.gw.table.devices == {}


def test_cot_during_identification_is_replayed(stack, db, pki, monkeypatch):
    """C1A-4: reports that arrive between the first SA and the end of identification are published after it."""
    orig = stack.gw.db_call

    async def slow(fn, *a, **kw):
        if fn.__name__ == "eud":
            await asyncio.sleep(0.5)
        return await orig(fn, *a, **kw)
    monkeypatch.setattr(stack.gw, "db_call", slow)
    r, w = stack.client(pki, "alice")
    w.write(sa("ANDROID-R1")); stack.run(0.1)
    w.write(b'<event version="2.0" uid="ANDROID-R1" type="b-t-f" how="h-e" time="x" start="x" stale="x"><point/><detail>chat</detail></event>')
    stack.run(1.0)
    bodies = [b for e, b, m in stack.ch.published if e == "cot_parser"]
    assert any(b"chat" in b for b in bodies)
    w.close(); stack.run(0.2)


def test_msgs_per_second_bucket_pauses_reading(stack, db, pki):
    """C1A-7 / C1B-5: a ping flood (tiny bytes) is bounded by UPLINK_MSGS_PER_S."""
    r, w = stack.client(pki, "alice"); w.write(sa("ANDROID-M1")); stack.run(0.3)
    ping = b'<event version="2.0" uid="ANDROID-M1-ping" type="t-x-c-t" time="x" start="x" stale="x"/>'
    w.write(ping * 200); stack.run(0.5)
    assert stack.gw.stats["uplink_paused"] >= 1
    w.close(); stack.run(0.2)


def test_device_channel_replaced_after_close():
    """C1A-3 / C1B-4: a channel closed by a 404/406 is re-placed on the next set_needed/reconcile."""
    loop = asyncio.new_event_loop()
    b = amqp.Broker(loop, "h", "u", "p", "1000"); b.conn = FakeConn()
    ch = FakeChannel(); b._on_pub_open(ch)
    d = b.device_channel("k", "U1", None, lambda body: True)
    first = d.ch
    assert d.ready and d.replaces == 1
    first.close_cb(first, "NOT_FOUND")                  # the broker closed it
    assert d.ch is None and not d.ready
    d.set_needed({("dms", "U1", "U1")})
    assert d.ch is not None and d.ready and d.replaces == 2 and ("dms", "U1", "U1") in d.placed


def test_return_then_ack_arms_the_retry():
    """C1A-6 / C1B-6: a returned+acked body is retried by a scheduled flush, not only on the next publish."""
    loop = asyncio.new_event_loop()
    b = amqp.Broker(loop, "h", "u", "p", "1000"); b.conn = FakeConn()
    ch = FakeChannel(); b._on_pub_open(ch)
    c = amqp.SessionCache(100, 1 << 20, "s"); b.register(c)
    b.publish_cot(c, "u", "a-f", b"one")
    ch.ret(b"one"); ch.ack(1)
    assert c.retry_armed
    c.retry_at = 0
    loop.run_until_complete(asyncio.sleep(2.2))        # RETURN_BACKOFF[0] = 2 s
    assert ch.published[-1][1] == b"one" and len(ch.published) == 2

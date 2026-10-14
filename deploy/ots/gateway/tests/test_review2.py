"""Regression tests for code-review round 2 (C2A-1..5): FAIL on 3354c37, PASS after the fixes."""
import asyncio
import socket

import pytest

from batman_eud_gateway import config
from batman_eud_gateway.server import Protocol
from tests.test_integration import Stack, free_port, sa, pki  # noqa: F401


@pytest.fixture
def stack(db, pki):
    s = config.load({"GATEWAY_MAX_PENDING": "8"})
    s = config.dataclasses.replace(s, tls_port=free_port(), health_port=free_port(), handshake_s=1.0)
    st = Stack(db, pki, s)
    yield st
    st.close()


def test_handshake_timeout_leaves_no_ghost_connection(stack):
    """C2A-1: a raw socket that never starts TLS is cleaned up after the handshake timeout (conns/pending 0)."""
    s = socket.create_connection(("127.0.0.1", stack.port)); stack.run(0.1)
    assert len(stack.gw.conns) == 1 and len(stack.gw.table.pending) == 1
    stack.run(1.6)                                     # handshake_s = 1 s
    assert stack.gw.conns == {} and stack.gw.table.pending == {}
    r0 = stack.gw.stats["refusals"]
    stack.gw.tick(10.0 ** 6); stack.gw.tick(10.0 ** 6 + 1)
    assert stack.gw.stats["refusals"] == r0           # no refusal spam from a ghost in tick()
    s.close()


def test_pool_eviction_during_handshake_is_cleaned_up(stack):
    """C2A-1 (eviction): sockets aborted by the pool while in the handshake state are removed from conns/pending."""
    raws = []
    for i in range(12):
        raws.append(socket.create_connection(("127.0.0.1", stack.port))); stack.run(0.05)
    stack.run(0.3)
    assert len(stack.gw.table.pending) <= 8 and len(stack.gw.conns) <= 8
    for s in raws:
        s.close()
    stack.run(1.6)
    assert stack.gw.conns == {} and stack.gw.table.pending == {}


def test_early_app_bytes_are_parked_then_processed(stack, pki):
    """C2A-2: app data handed to the protocol before start_tls() returned is parked and replayed, not dropped."""
    p = Protocol(stack.gw, stack.port)
    p.conn = type("C", (), {"closed": False, "addr": "x", "user_id": None, "device": None, "last_rx": 0, "last_msg": 0,
                             "uplink": None, "uplink_msgs": None})()
    assert p.tls_done is False
    p.data_received(b"<event ")                        # before tls_done: parked
    p.data_received(b'uid="u" type="t-x-c-t"/>')
    assert p._early == [b"<event ", b'uid="u" type="t-x-c-t"/>'] and stack.gw.stats.get("early_dropped", 0) == 0
    # and the real path: a client that writes its SA immediately after the handshake is identified
    r, w = stack.client(pki, "alice"); w.write(sa("ANDROID-E1")); stack.run(0.5)
    assert any(d.uid == "ANDROID-E1" for d in stack.gw.table.devices.values())
    w.close(); stack.run(0.2)


def test_double_connection_closed_does_not_end_the_reconnected_device(stack, db, pki, monkeypatch):
    """C2A-3: the socket dies during identify's DB wait, the phone reconnects; identify's late 'closed during
    identification' must not end the NEW device."""
    orig = stack.gw.db_call

    async def slow(fn, *a, **kw):
        if fn.__name__ == "write_eud":
            await asyncio.sleep(0.8)
        return await orig(fn, *a, **kw)
    monkeypatch.setattr(stack.gw, "db_call", slow)
    r1, w1 = stack.client(pki, "alice"); w1.write(sa("ANDROID-D1")); stack.run(0.2)
    w1.transport.abort(); stack.run(0.3)
    r2, w2 = stack.client(pki, "alice"); w2.write(sa("ANDROID-D1")); stack.run(1.5)
    devs = [d for d in stack.gw.table.devices.values() if d.uid == "ANDROID-D1"]
    assert len(devs) == 1 and devs[0].current is not None and not devs[0].current.closed and not devs[0].ended
    assert db.eud("ANDROID-D1")["last_status"] == "Connected"
    w2.close(); stack.run(0.3)


def test_stop_sends_one_goodbye_per_device(stack, db, pki):
    """C2A-4: at stop, the sockets' close must not ALSO end the devices (one goodbye, one row update each)."""
    r, w = stack.client(pki, "alice"); w.write(sa("ANDROID-S1")); stack.run(0.3)
    n0 = sum(1 for e, b, m in stack.ch.published if e == "cot_parser" and b"t-x-d-d" in b)
    stack.gw.stopping = True
    for proto in list(stack.gw.conns.values()):
        proto.close("stop")
    stack.run(0.3)
    n1 = sum(1 for e, b, m in stack.ch.published if e == "cot_parser" and b"t-x-d-d" in b)
    assert n1 == n0                                    # the stop sequence (not run here) owns the goodbye
    assert stack.gw.table.devices == {}

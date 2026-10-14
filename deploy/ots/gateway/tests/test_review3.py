"""Regression tests for code-review round 3 (closure) and the security review: SEC-1, SEC-2, C3A-1, C3A-2,
C3B-1, C3B-2, C3B-3, C3B-4. Every test FAILS on be23548 and PASSES after the fixes (the reviewers' probes, ported)."""
import asyncio
import logging
import time
import types

import pytest
from sqlalchemy import text

from batman_eud_gateway import amqp, config
from tests.test_amqp import FakeChannel, FakeConn
from tests.test_integration import Stack, free_port, sa, pki  # noqa: F401

CHAT = (b'<event version="2.0" uid="%s" type="b-t-f" how="h-e" time="x" start="x" stale="x">'
        b'<point/><detail>chat-%s</detail></event>')


class Capture(logging.Handler):
    def __init__(self):
        super().__init__(level=logging.INFO)
        self.recs = []

    def emit(self, record):
        self.recs.append((record.levelno, record.getMessage()))

    def count(self, needle):
        return sum(1 for lv, m in self.recs if needle in m)


@pytest.fixture
def cap():
    h = Capture()
    root = logging.getLogger()
    old = root.level
    root.setLevel(logging.INFO)
    root.addHandler(h)
    yield h
    root.removeHandler(h)
    root.setLevel(old)


@pytest.fixture
def stack(db, pki):
    s = config.load({"GATEWAY_SUPERSEDE_QUIET_S": "1", "GATEWAY_SUPERSEDE_MAX_S": "2"})
    s = config.dataclasses.replace(s, tls_port=free_port(), health_port=free_port())
    st = Stack(db, pki, s)
    yield st
    st.close()


# ---- SEC-1: a uid live under another user ------------------------------------------------------------------
def test_uid_live_under_another_user_is_refused_while_the_row_is_missing(stack, db, pki, monkeypatch, cap):
    """SEC P1: bob's row write fails (DB down); alice (valid cert) claims bob's uid X -> refused; one device."""
    def boom(*a, **k):
        raise RuntimeError("db write down")
    monkeypatch.setattr(db, "write_eud", boom)
    monkeypatch.setattr(db, "minimal_eud", boom)
    rb, wb = stack.client(pki, "bob"); wb.write(sa("X", "BOB1")); stack.run(0.6)
    ra, wa = stack.client(pki, "alice"); wa.write(sa("X", "ALICE1")); stack.run(0.6)
    devs = list(stack.gw.table.devices.values())
    assert [d.user_id for d in devs] == [2], [(d.uid, d.user_id) for d in devs]
    assert list(stack.broker.devices) == ["2|X"]
    assert cap.count("uid live under another user") == 1
    wa.close(); wb.close(); stack.run(0.2)


def test_uid_theft_in_the_row_write_window_loses(stack, db, pki, monkeypatch, cap):
    """SEC P1b: the DB is up, bob's write_eud is slow; alice's SELECT sees no row and adopts -> alice's device is
    refused in memory (bob's device is live), the row is bob's."""
    real = db.write_eud

    def slow(uid, user_id, *a, **k):
        if user_id == 2:
            time.sleep(1.0)
        return real(uid, user_id, *a, **k)
    monkeypatch.setattr(db, "write_eud", slow)
    rb, wb = stack.client(pki, "bob"); wb.write(sa("Y", "BOB2")); stack.run(0.3)
    ra, wa = stack.client(pki, "alice"); wa.write(sa("Y", "ALICE2")); stack.run(1.5)
    with db.engine.connect() as c:
        row = c.execute(text("SELECT uid, user_id FROM euds WHERE uid='Y'")).first()
    assert row is not None and row[1] == 2, row
    assert all(d.user_id == 2 for d in stack.gw.table.devices.values())
    wa.close(); wb.close(); stack.run(0.2)


def test_adopt_never_overwrites_another_owner(db):
    """SEC test_a / test_a2: an adopting write over a row owned by someone else writes nothing and says so."""
    assert db.write_eud("D1", 2, "BOBX", "Pixel", "34", "ATAK", "5", None, None, None, None, adopt=True) == "inserted"
    assert db.write_eud("D1", 1, "ALX", "Pixel", "34", "ATAK", "5", None, None, None, None, adopt=True) == "owned-elsewhere"
    assert db.minimal_eud("D2", 2, None, adopt=True) == "inserted"
    assert db.minimal_eud("D2", 1, None, adopt=True) == "owned-elsewhere"
    assert db.minimal_eud("D2", 2, None, adopt=True) == "updated"
    with db.engine.connect() as c:
        rows = c.execute(text("SELECT uid, user_id FROM euds WHERE uid IN ('D1','D2') ORDER BY uid")).all()
    assert [tuple(r) for r in rows] == [("D1", 2), ("D2", 2)]


def test_row_taken_first_by_another_user_ends_the_late_device(stack, db, pki, monkeypatch, cap):
    """the DB side of SEC-1: alice's write finds the row already owned by bob (bob's device is NOT live, so the
    in-memory rule does not fire): alice's device is ended, refusal logged, the row stays bob's."""
    real = db.write_eud

    def race(uid, user_id, *a, **k):
        if user_id == 1:                     # bob's identification lands between alice's SELECT and her write
            real("Z", 2, "BOBZ", None, None, None, None, None, None, None, None, True)
        return real(uid, user_id, *a, **k)
    monkeypatch.setattr(db, "write_eud", race)
    ra, wa = stack.client(pki, "alice"); wa.write(sa("Z", "ALICEZ")); stack.run(1.0)
    assert stack.gw.table.devices == {}
    assert db.eud("Z")["user_id"] == 2
    assert cap.count("owned by another user") >= 1
    wa.close(); stack.run(0.2)


# ---- SEC-2: per-message log lines are rate limited ---------------------------------------------------------
def test_malformed_messages_log_one_line_per_minute(stack, db, pki, cap):
    r, w = stack.client(pki, "alice"); w.write(sa("L1", "LOG1")); stack.run(0.4)
    w.write(b"<event/>" * 200); stack.run(0.8)
    assert stack.gw.stats["malformed"] == 200
    assert cap.count("malformed message") == 1
    w.close(); stack.run(0.2)


# ---- C3A-1: a late Connected write never lands after the end's Disconnected ------------------------------
def test_periodic_reconcile_racing_the_end_leaves_disconnected(stack, db, pki, monkeypatch, cap):
    """A3 P14: the cycle's reconcile awaits the DB when the socket dies -> the row ends Disconnected."""
    r, w = stack.client(pki, "alice"); w.write(sa("ANDROID-PR")); stack.run(0.4)
    d = next(iter(stack.gw.table.devices.values()))
    orig = stack.gw.db_call

    async def slow(fn, *a, **kw):
        if fn.__name__ == "needed_bindings":
            await asyncio.sleep(0.6)
        return await orig(fn, *a, **kw)
    monkeypatch.setattr(stack.gw, "db_call", slow)
    d.last_reconcile = 0
    stack.gw.tick(time.monotonic()); stack.run(0.2)
    w.transport.abort(); stack.run(1.5)
    assert stack.gw.table.devices == {} and cap.count("ended ANDROID-PR") == 1
    assert db.eud("ANDROID-PR")["last_status"] == "Disconnected"


@pytest.mark.parametrize("fn_name", ["write_eud", "needed_bindings", "candidate_bindings", "set_connected"])
def test_dying_during_identify_leaves_disconnected(stack, db, pki, monkeypatch, cap, fn_name):
    """A3 P2 (no reconnect): the socket dies while identify awaits <fn_name> -> row Disconnected or absent."""
    uid = "ANDROID-D-" + fn_name
    orig = stack.gw.db_call

    async def slow(fn, *a, **kw):
        if fn.__name__ == fn_name:
            await asyncio.sleep(0.6)
        return await orig(fn, *a, **kw)
    monkeypatch.setattr(stack.gw, "db_call", slow)
    r, w = stack.client(pki, "alice")
    w.write(sa(uid) + CHAT % (uid.encode(), b"first")); stack.run(0.25)
    w.transport.abort(); stack.run(1.8)
    assert stack.gw.table.devices == {} and stack.gw.conns == {}
    row = db.eud(uid)
    assert row is None or row["last_status"] == "Disconnected", row
    # C3A-2: the SA and the chat that died with the socket are counted, never silent
    assert stack.gw.stats["pre_ident_dropped"] >= 1


# ---- C3A-2: CoT of a connection that dies before identification is counted ------------------------------
def test_pre_ident_messages_of_a_dying_connection_are_counted(stack, db, pki, monkeypatch):
    orig = stack.gw.db_call

    async def slow(fn, *a, **kw):
        if fn.__name__ == "user_by_name":
            await asyncio.sleep(0.6)
        return await orig(fn, *a, **kw)
    monkeypatch.setattr(stack.gw, "db_call", slow)
    r, w = stack.client(pki, "alice")
    w.write(sa("ANDROID-E1") + CHAT % (b"ANDROID-E1", b"c1") + CHAT % (b"ANDROID-E1", b"c2")); stack.run(0.2)
    w.transport.abort(); stack.run(0.8)
    assert stack.gw.stats["pre_ident_dropped"] == 3


# ---- C3B-1 / C3B-2: one channel per device, none for an ended device ---------------------------------------
class DeferredConn(FakeConn):
    """conn.channel() delivers OpenOk on the NEXT loop iteration, as pika does."""
    def __init__(self, loop):
        super().__init__(); self.loop = loop

    def channel(self, on_open_callback):
        ch = FakeChannel(); self.channels.append(ch)
        self.loop.call_soon(on_open_callback, ch)
        return ch


def deferred_broker(loop):
    b = amqp.Broker(loop, "h", "u", "p", "1000")
    b.conn = DeferredConn(loop)
    b._on_pub_open(FakeChannel())
    assert b.open
    return b


def test_place_before_openok_opens_one_channel():
    """B3 P1: device_channel() then set_needed() (identify's first reconcile) before OpenOk -> ONE channel, one
    consumer; the device's end leaves no open channel with a consumer."""
    loop = asyncio.new_event_loop()
    b = deferred_broker(loop)
    d = b.device_channel("1|U1", "U1", None, lambda body: True)
    d.set_needed({("dms", "U1", "U1")}, {("groups", "U1", "__ANON__.OUT")})
    loop.run_until_complete(asyncio.sleep(0.05))
    chans = b.conn.channels
    assert d.replaces == 1 and len(chans) == 1 and list(chans[0].consumers) == ["U1"]
    d.unbind_placed_and_close(); b.drop_device("1|U1")
    assert [i for i, ch in enumerate(chans) if ch.is_open and ch.consumers] == []
    loop.close()


def test_device_ended_before_openok_gets_no_consumer():
    """B3 P2: the device ends before OpenOk -> the channel is closed on open, nothing declared/bound/consumed."""
    loop = asyncio.new_event_loop()
    b = deferred_broker(loop)
    d = b.device_channel("1|U2", "U2", "CS2", lambda body: False)
    d.set_needed({("dms", "U2", "U2")})
    d.unbind_placed_and_close(); b.drop_device("1|U2")
    loop.run_until_complete(asyncio.sleep(0.05))
    zombies = [ch for ch in b.conn.channels if ch.is_open and ch.consumers]
    assert zombies == [] and d.ch is None and not d.ready
    loop.close()


# ---- C3B-3: returns and multiple nacks keep the session order -----------------------------------------------
def test_returns_and_multiple_nack_keep_the_order():
    loop = asyncio.new_event_loop()
    b = amqp.Broker(loop, "h", "u", "p", "1000"); b.conn = FakeConn()
    ch = FakeChannel(); b._on_pub_open(ch)
    c = amqp.SessionCache(100, 1 << 20, "s"); b.register(c)
    for body in (b"1", b"2", b"3"):
        b.publish_cot(c, "u", "b-t-f", body)
    for body in (b"1", b"2", b"3"):
        ch.ret(body)
    for t in (1, 2, 3):
        ch.ack(t)
    assert [e.body for e in c.q] == [b"1", b"2", b"3"]
    c2 = amqp.SessionCache(100, 1 << 20, "s2"); b.register(c2)
    for body in (b"a", b"b", b"c"):
        b.publish_cot(c2, "u", "b-t-f", body)
    last = max(b._unacked)
    b._on_ack(types.SimpleNamespace(method=types.SimpleNamespace(NAME="Basic.Nack", delivery_tag=last, multiple=True)))
    assert [e.body for e in c2.q] == [b"a", b"b", b"c"]
    loop.close()


# ---- C3B-4: a Disconnected write that failed at the end is retried on the cycle ----------------------------
def test_end_with_the_db_down_is_retried(stack, db, pki, cap):
    r, w = stack.client(pki, "alice"); w.write(sa("ANDROID-X1")); stack.run(0.4)
    assert db.eud("ANDROID-X1")["last_status"] == "Connected"
    orig = stack.gw.db_call

    async def down(fn, *a, **kw):
        if fn.__name__ in ("set_disconnected", "minimal_eud"):
            raise RuntimeError("connection refused (ots-db down)")
        return await orig(fn, *a, **kw)
    stack.gw.db_call = down
    w.transport.abort(); stack.run(0.5)
    assert db.eud("ANDROID-X1")["last_status"] == "Connected" and "ANDROID-X1" in stack.gw.pending_disconnects
    stack.gw.db_call = orig                              # the DB is back
    stack.gw.tick(time.monotonic() + 100); stack.run(0.3)
    assert db.eud("ANDROID-X1")["last_status"] == "Disconnected"
    assert stack.gw.pending_disconnects == {} and cap.count("Disconnected (retried)") == 1


def test_pending_disconnect_is_cancelled_by_a_live_device(stack, db, pki):
    """the uid came back before the retry: its reconcile owns the row; the retry must not flip it."""
    stack.gw.pending_disconnects["ANDROID-R1"] = time.monotonic() + 600
    r, w = stack.client(pki, "alice"); w.write(sa("ANDROID-R1")); stack.run(0.4)
    stack.gw.tick(time.monotonic() + 100); stack.run(0.3)
    assert stack.gw.pending_disconnects == {}
    assert db.eud("ANDROID-R1")["last_status"] == "Connected"
    w.close(); stack.run(0.3)

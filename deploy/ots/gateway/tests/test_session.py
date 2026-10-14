import pytest

from batman_eud_gateway import config
from batman_eud_gateway.session import Conn, Refused, Table

S = config.load({"GATEWAY_MAX_PENDING": "3", "GATEWAY_MAX_DEVICES": "4", "GATEWAY_MAX_DEVICES_PER_USER": "2",
                 "GATEWAY_NEW_DEVICES_BURST": "2", "GATEWAY_NEW_DEVICES_PER_H": "0",
                 "GATEWAY_MAX_CONNS_PER_DEVICE": "3", "GATEWAY_MAX_PENDING_PER_USER": "2"})


def conn(cid, port=8089, addr="10.0.0.1", user=1, name="alice"):
    c = Conn(cid=cid, port=port, addr=addr, user_id=user, username=name)
    c.closed_with = []
    c.close = lambda r: c.closed_with.append(r)
    return c


def table():
    return Table(S, mem_reserve_ok=lambda: True)


def test_pending_pool_evicts_oldest_not_newcomer():
    t = table()
    cs = [conn(i) for i in range(4)]
    for i, c in enumerate(cs):
        c.opened = float(i)
        t.accept(c)
    assert cs[0].closed_with == ["pending pool full: evicted (oldest)"]
    assert set(t.pending) == {1, 2, 3}


def test_memory_reserve_refuses_at_accept():
    t = Table(S, mem_reserve_ok=lambda: False)
    with pytest.raises(Refused):
        t.accept(conn(1))


def test_per_user_pending_cap():
    t = table()
    a, b, c = conn(1), conn(2), conn(3)
    a.opened, b.opened, c.opened = 1.0, 2.0, 3.0
    for x in (a, b, c):
        t.accept(x); t.after_handshake(x)
    assert a.closed_with and not b.closed_with and not c.closed_with


def test_deadlines():
    t = table()
    c = conn(1); c.opened = 0.0; c.last_msg = 0.0
    assert t.pending_deadline_due(c, 30.0) is None
    assert "complete message" in t.pending_deadline_due(c, 61.0)
    c.last_msg = 100.0
    assert "hard limit" in t.pending_deadline_due(c, 121.0)   # pings cannot extend the hard limit


def test_identify_new_device_and_caps():
    t = table()
    c1 = conn(1); t.accept(c1)
    d, new = t.identify(c1, "U1", "ALPHA", True)
    assert new and d.current is c1 and c1.device is d and 1 not in t.pending
    c2 = conn(2); t.accept(c2)
    d2, new2 = t.identify(c2, "U2", None, False)
    assert new2
    c3 = conn(3); t.accept(c3)
    with pytest.raises(Refused) as e:
        t.identify(c3, "U3", None, False)          # per-user cap 2
    assert e.value.reason == "per-user device cap"
    # another user: the new-device bucket (burst 2, no refill)
    b1, b2, b3 = conn(4, user=2, name="bob"), conn(5, user=2, name="bob"), conn(6, user=2, name="bob")
    for x in (b1, b2, b3):
        t.accept(x)
    t.identify(b1, "B1", None, False)
    t.identify(b2, "B2", None, False)              # 4th device: at the cap, still admitted
    with pytest.raises(Refused) as e:
        t.identify(b3, "B3", None, False)          # 5th: device cap (checked before the per-user cap)
    assert e.value.reason == "device cap"


def test_new_device_rate_bucket():
    s = config.load({"GATEWAY_NEW_DEVICES_BURST": "1", "GATEWAY_NEW_DEVICES_PER_H": "0"})
    t = Table(s, lambda: True)
    a, b = conn(1), conn(2)
    t.accept(a); t.accept(b)
    t.identify(a, "X1", None, False)
    with pytest.raises(Refused) as e:
        t.identify(b, "X2", None, False)
    assert e.value.reason == "new-device rate"
    # the same uid again is not a "new device"
    c = conn(3); t.accept(c)
    d, new = t.identify(c, "X1", None, False)
    assert not new and d.current is c


def test_supersede_keeps_old_reading_then_closes_excess():
    t = table()
    events = []
    t.on_supersede = lambda d, old, new: events.append((old.cid, new.cid))
    c1 = conn(1); t.accept(c1); d, _ = t.identify(c1, "U1", None, False)
    c1.last_rx = 0.0
    c2 = conn(2); t.accept(c2); d2, new = t.identify(c2, "U1", None, False)
    assert d2 is d and not new and d.current is c2 and d.draining == [c1] and events == [(1, 2)]
    assert c1.superseded_at is not None and c1.deadline is not None
    # outage + 20 capped at 120
    assert c1.deadline - c1.superseded_at <= 120.0
    c3 = conn(3); t.accept(c3); t.identify(c3, "U1", None, False)
    assert d.current is c3 and set(x.cid for x in d.draining) == {1, 2}
    c4 = conn(4); t.accept(c4); t.identify(c4, "U1", None, False)
    # max 3 conns: current + 2 draining -> the oldest draining (c1) closed
    assert c1.closed_with == ["too many connections for this device"]
    assert set(x.cid for x in d.draining) == {2, 3}


def test_superseded_deadline_extends_on_rx_and_newer_ended_first():
    t = table()
    c1 = conn(1); t.accept(c1); d, _ = t.identify(c1, "U1", None, False)
    c2 = conn(2); t.accept(c2); t.identify(c2, "U1", None, False)
    now = c1.superseded_at
    base = c1.deadline
    t.note_rx(c1, now + 5)
    assert c1.deadline >= base            # extended by QUIET_S after a byte
    assert not t.superseded_due(c1, now + 1)
    assert t.superseded_due(c1, c1.deadline + 0.1)
    # the newer connection ends first: c1 is promoted to current (B2-10), not left orphaned
    assert t.connection_closed(c2) is None
    assert d.current is c1 and c1.superseded_at is None and d.draining == []


def test_device_ends_on_last_connection():
    t = table()
    c1 = conn(1); t.accept(c1); d, _ = t.identify(c1, "U1", None, False)
    assert t.connection_closed(c1) is d and d.ended and d.key not in t.devices


def test_sendq_bounds_coalesce_and_drop():
    t = table()
    c1 = conn(1); t.accept(c1); d, _ = t.identify(c1, "U1", None, False)
    sa = lambda u, n: ('<event version="2.0" uid="%s" type="a-f-G-U-C"><detail>%d</detail></event>' % (u, n)).encode()
    for i in range(205):
        d.enqueue(sa("P%d" % (i % 10), i), None, None)
    assert len(d.sendq) <= 200 and d.sendq_dropped > 0
    # the bound at entry 201 coalesced to one newest SA per uid (10); the 4 later ones were appended
    uids = [p[p.find(b'uid="') + 5:p.find(b'"', p.find(b'uid="') + 5)] for p in d.sendq]
    assert len(set(uids)) == 10 and len(uids) <= 14
    # the newest report of each uid survived (sequence numbers 195..204 are the last per uid)
    nums = sorted(int(p[p.find(b"<detail>") + 8:p.find(b"</detail>")]) for p in d.sendq)
    assert nums[-10:] == list(range(195, 205))

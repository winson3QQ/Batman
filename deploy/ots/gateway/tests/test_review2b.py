"""Regression tests for code-review round 2, reviewer B (C2B-2, C2B-3, C2B-5) and the rc 1 node finding
(reconcile racing the row insert): FAIL on cdb4c36, PASS after the fixes."""
import asyncio
import time

import pytest

from batman_eud_gateway import amqp, config
from tests.test_integration import Stack, free_port, sa, pki  # noqa: F401


@pytest.fixture
def stack(db, pki):
    s = config.load({})
    s = config.dataclasses.replace(s, tls_port=free_port(), health_port=free_port())
    st = Stack(db, pki, s)
    yield st
    st.close()


def test_burst_during_cert_lookup_is_kept(stack, db, pki, monkeypatch):
    """C2B-5 (the e2e P3 loss on rc 1): five reports in the first write while the cert lookup runs -> the device is
    the FIRST SA's uid and all five are published (rc 1 kept only the newest SA, 4 of 5 lost)."""
    orig = stack.gw.db_call

    async def slow(fn, *a, **kw):
        if fn.__name__ == "user_by_name":
            await asyncio.sleep(0.5)
        return await orig(fn, *a, **kw)
    monkeypatch.setattr(stack.gw, "db_call", slow)
    r, w = stack.client(pki, "alice")
    w.write(b"".join(sa("ANDROID-B%d" % k) for k in range(1, 6))); stack.run(1.5)
    devs = [d.uid for d in stack.gw.table.devices.values()]
    assert devs == ["ANDROID-B1"]
    bodies = [b for e, b, m in stack.ch.published if e == "cot_parser"]
    for k in range(1, 6):
        assert any(('uid=\\"ANDROID-B%d\\"' % k).encode() in b for b in bodies), k
    w.close(); stack.run(0.2)


def test_amqp_down_clock_starts_at_start():
    """C2B-2: a long wait for the schema before the broker is started must not count as AMQP down time."""
    loop = asyncio.new_event_loop()
    b = amqp.Broker(loop, "h", "u", "p", "1000")
    b.down_since = time.monotonic() - 1000          # as if the object was built 1000 s ago
    b._connect = lambda: None                        # no real connection in the test
    b.start()
    assert time.monotonic() - b.down_since < 1.0


def test_fresh_device_is_not_reconciled_concurrently_with_identify(stack, db, pki):
    """rc 1 on 04: the 1 s tick reconciled a brand-new device at once (last_reconcile 0) and raced the row insert."""
    r, w = stack.client(pki, "alice"); w.write(sa("ANDROID-T1")); stack.run(0.4)
    dev = next(iter(stack.gw.table.devices.values()))
    assert time.monotonic() - dev.last_reconcile < 5 and dev.row_retry_at > time.monotonic()
    w.close(); stack.run(0.2)


def test_insert_is_race_free(db):
    """the row insert no longer does SELECT-then-INSERT: inserting over an existing row updates it, never raises."""
    db.minimal_eud("R1", 1, None, adopt=True)
    assert db.write_eud("R1", 1, "CS", "d", "o", "p", "v", None, None, None, None, adopt=False) == "updated"
    db.minimal_eud("R1", 1, None, adopt=False)       # second minimal row over an existing one: update, no raise
    assert db.eud("R1")["device"] == "d"

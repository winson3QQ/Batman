"""Publisher logic with a FAKE channel: return/nack/loss/blocked, firehose never retried, order kept,
cache bounds + coalescing. No broker."""
import asyncio
import types

import pytest

from batman_eud_gateway import amqp


class FakeChannel:
    def __init__(self):
        self.published = []      # (exchange, body, mandatory)
        self.is_open = True
        self.close_cb = None
        self.return_cb = None
        self.ack_cb = None
        self.bound = set()
        self.consumers = {}
        self.acked = []
        self.nacked = []

    def add_on_close_callback(self, cb): self.close_cb = cb
    def add_on_return_callback(self, cb): self.return_cb = cb
    def exchange_declare(self, exchange, exchange_type, durable, callback): callback(None)
    def queue_declare(self, queue, callback=None, passive=False):
        if callback:
            callback(types.SimpleNamespace(method=types.SimpleNamespace(message_count=0)))
    def queue_bind(self, queue, exchange, routing_key, callback=None):
        self.bound.add((exchange, queue, routing_key))
        if callback: callback(None)
    def queue_unbind(self, queue, exchange, routing_key, callback=None):
        self.bound.discard((exchange, queue, routing_key))
        if callback: callback(None)
    def confirm_delivery(self, ack_nack_callback, callback):
        self.ack_cb = ack_nack_callback; callback(None)
    def basic_publish(self, exchange, routing_key, body, properties=None, mandatory=False):
        self.published.append((exchange, body, mandatory))
    def basic_qos(self, prefetch_count, callback=None):
        if callback: callback(None)
    def basic_consume(self, queue, on_message_callback, auto_ack=False):
        self.consumers[queue] = on_message_callback
        return "ctag-" + queue
    def basic_ack(self, delivery_tag): self.acked.append(delivery_tag)
    def basic_nack(self, delivery_tag, requeue=True): self.nacked.append(delivery_tag)
    def close(self):
        self.is_open = False
        if self.close_cb: self.close_cb(self, "closed by client")

    # test helpers
    def ack(self, tag, multiple=False):
        self.ack_cb(types.SimpleNamespace(method=types.SimpleNamespace(NAME="Basic.Ack", delivery_tag=tag, multiple=multiple)))
    def nack(self, tag):
        self.ack_cb(types.SimpleNamespace(method=types.SimpleNamespace(NAME="Basic.Nack", delivery_tag=tag, multiple=False)))
    def ret(self, body):
        self.return_cb(self, types.SimpleNamespace(reply_text="NO_ROUTE"), None, body)


class FakeConn:
    def __init__(self):
        self.is_open = True; self.is_closed = False; self.channels = []
    def channel(self, on_open_callback):
        ch = FakeChannel(); self.channels.append(ch); on_open_callback(ch); return ch
    def close(self): self.is_closed = True; self.is_open = False


def make_broker(loop):
    b = amqp.Broker(loop, "h", "u", "p", "1000")
    b.conn = FakeConn()
    ch = FakeChannel()
    b._on_pub_open(ch)          # declares + confirm_delivery -> open
    assert b.open
    return b, ch


def test_publish_confirm_and_order():
    loop = asyncio.new_event_loop()
    b, ch = make_broker(loop)
    c = amqp.SessionCache(100, 1 << 20, "s")
    b.register(c)
    b.publish_cot(c, "u", "a-f", b"one")
    b.publish_cot(c, "u", "b-t-f", b"two")
    assert [p[1] for p in ch.published] == [b"one", b"two"] and all(p[2] for p in ch.published)
    assert c.inflight == 2 and len(c) == 0
    ch.ack(2, multiple=True)
    assert c.inflight == 0 and b.stats["confirmed"] == 2


def test_firehose_not_mandatory_and_never_retried():
    loop = asyncio.new_event_loop()
    b, ch = make_broker(loop)
    assert b.publish_aux("firehose", b"fh")
    ex, body, mand = ch.published[-1]
    assert ex == "firehose" and mand is False
    # a return for a firehose body matches no cache entry: nothing is retried
    ch.ret(b"fh")
    assert b.stats["returned"] == 1 and b.cached_total() == 0


def test_return_goes_to_head_with_backoff_then_retries():
    loop = asyncio.new_event_loop()
    b, ch = make_broker(loop)
    c = amqp.SessionCache(100, 1 << 20, "s"); b.register(c)
    b.publish_cot(c, "u", "a-f", b"one")
    b.publish_cot(c, "u", "a-f", b"two")
    ch.ret(b"one")                 # cot_parser queue gone: body one returned
    ch.ack(1)                      # then acked (a return is followed by an ack)
    assert c.q[0].body == b"one" and c.q[0].returned and c.inflight == 1
    assert c.retry_at > 0
    # the head waits for backoff; nothing else is published meanwhile
    n = len(ch.published)
    b._flush(c)
    assert len(ch.published) == n
    # after the backoff: head-only retry
    c.retry_at = 0
    ch.ack(2)                      # two acked -> inflight 0 -> flush
    assert ch.published[-1][1] == b"one"


def test_nack_requeues_head():
    loop = asyncio.new_event_loop()
    b, ch = make_broker(loop)
    c = amqp.SessionCache(100, 1 << 20, "s"); b.register(c)
    b.publish_cot(c, "u", "a-f", b"one")
    ch.nack(1)
    assert b.stats["nacked"] == 1 and len(c) >= 0   # retried at once (head) -> published again
    assert ch.published[-1][1] == b"one"


def test_connection_loss_requeues_unacked_in_order_and_flushes_on_reopen():
    loop = asyncio.new_event_loop()
    b, ch = make_broker(loop)
    c = amqp.SessionCache(100, 1 << 20, "s"); b.register(c)
    for body in (b"1", b"2", b"3"):
        b.publish_cot(c, "u", "b-t-f", body)
    b._on_conn_closed(b.conn, "lost")
    assert not b.open and [e.body for e in c.q] == [b"1", b"2", b"3"] and c.inflight == 0
    ch2 = FakeChannel()
    b._closing = True              # no reconnect timer in the test
    b._on_pub_open(ch2)
    assert [p[1] for p in ch2.published] == [b"1", b"2", b"3"]


def test_blocked_caches_and_unblocked_flushes():
    loop = asyncio.new_event_loop()
    b, ch = make_broker(loop)
    c = amqp.SessionCache(100, 1 << 20, "s"); b.register(c)
    b._on_blocked(None, None)
    b.publish_cot(c, "u", "a-f", b"x")
    assert ch.published == [] and len(c) == 1
    b._on_unblocked(None, None)
    assert ch.published[-1][1] == b"x"


def test_cache_bounds_coalesce_then_drop_oldest():
    c = amqp.SessionCache(max_entries=3, max_bytes=1 << 20, name="s")
    c.push_tail(amqp.CacheEntry("u1", "a-f-G", b"p1"))
    c.push_tail(amqp.CacheEntry("u1", "b-t-f", b"chat"))
    c.push_tail(amqp.CacheEntry("u1", "a-f-G", b"p2"))
    c.push_tail(amqp.CacheEntry("u1", "a-f-G", b"p3"))     # over 3 -> coalesce a-* of u1: keep p3 only
    assert [e.body for e in c.q] == [b"chat", b"p3"] and c.dropped == 2
    c.push_tail(amqp.CacheEntry("u2", "b-t-f", b"c2"))
    c.push_tail(amqp.CacheEntry("u2", "b-t-f", b"c3"))     # 4 entries, nothing to coalesce -> drop oldest
    assert [e.body for e in c.q] == [b"p3", b"c2", b"c3"] and c.dropped == 3

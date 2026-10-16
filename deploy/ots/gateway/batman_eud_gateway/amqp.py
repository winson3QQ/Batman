"""M6 Publisher and M7 per-device consumer channels over ONE pika AsyncioConnection.

Threading: pika's AsyncioConnection drives its callbacks on the gateway's event loop, so everything here
runs on the loop; nothing blocks. The gateway's other components call in through plain methods.

Publisher (M6):
- one publishing channel with Confirm.Select; `mandatory` on the cot_parser publish ONLY (B2-7);
- every cot_parser body is held in its session's cache until its Basic.Ack (multiple honoured);
  a Basic.Nack or a Basic.Return puts it back at the HEAD of the cache; head-only retry with backoff;
- per-session cache bounded (entries + bytes); overflow coalesces `a-*` per uid, then drops the oldest;
- on connection/channel loss every unacked body goes back in publish order and the connection reconnects
  with backoff 1,2,4,8,16,30 s ±25 %; order per session is kept (a new body queues behind a non-empty cache);
- on every connection open: declare the seven exchanges with app.py's exact arguments and the cot_parser
  queue + binding (cot_parser's defaults), then flush every cache;
- broker blocked (memory alarm) -> cache, no timeout.

Consumers (M7): one channel per device; queue_declare(uid) (+callsign), bindings reconciled (bind the
delta, unbind the gateway-placed delta), basic_qos(50), basic_consume with manual ack: the message is
acked right after it was appended to the session's send queue. A channel exception closes that device's
channel only; it is re-placed on the next reconcile.
"""
from __future__ import annotations

import collections
import logging
import random
import time
from typing import Callable

import pika
import pika.exceptions
from pika.adapters.asyncio_connection import AsyncioConnection

log = logging.getLogger("gateway.amqp")

EXCHANGES = (  # app.py:163-172 exactly (type, durable)
    ("dms", "direct", True), ("cot_parser", "direct", True), ("chatrooms", "direct", True),
    ("missions", "topic", True), ("groups", "topic", True), ("firehose", "fanout", True),
    ("flask-socketio", "fanout", False),
)
BACKOFF = (1, 2, 4, 8, 16, 30)
RETURN_BACKOFF = (2, 4, 8)


class CacheEntry:
    __slots__ = ("uid", "etype", "body", "returned")

    def __init__(self, uid: str | None, etype: str, body: bytes):
        self.uid, self.etype, self.body, self.returned = uid, etype, body, False


class SessionCache:
    """Per-session bounded FIFO of cot_parser bodies not yet acked (M6/R9 bounds)."""

    def __init__(self, max_entries: int, max_bytes: int, name: str):
        self.max_entries, self.max_bytes, self.name = max_entries, max_bytes, name
        self.q: collections.deque[CacheEntry] = collections.deque()
        self.bytes = 0
        self.dropped = 0
        self.inflight = 0          # entries published, awaiting ack (not in q)
        self.retry_at = 0.0        # monotonic; > now means the head waits (return backoff)
        self.retry_n = 0
        self.hold = False          # M5 store-before-route: True until the device's euds row exists
        self.ending = False        # the device ended: unregister once empty and fully acked
        self.retry_armed = False   # a head retry is scheduled on the loop

    def __len__(self) -> int:
        return len(self.q)

    def push_tail(self, e: CacheEntry) -> None:
        self.q.append(e); self.bytes += len(e.body)
        self._bound()

    def push_head(self, e: CacheEntry) -> None:
        """A returned / nacked entry goes back to the head, AFTER the entries already returned before it: returns
        and multiple nacks arrive in publish order, so the retry order stays the session order (C3B-3)."""
        k = 0
        while k < len(self.q) and self.q[k].returned:
            k += 1
        self.q.insert(k, e); self.bytes += len(e.body)
        self._bound()

    def pop_head(self) -> CacheEntry:
        e = self.q.popleft(); self.bytes -= len(e.body)
        return e

    def _bound(self) -> None:
        if len(self.q) <= self.max_entries and self.bytes <= self.max_bytes:
            return
        # 1. coalesce position reports: keep only the newest a-* per uid
        seen: set = set()
        kept: collections.deque[CacheEntry] = collections.deque()
        for e in reversed(self.q):
            if e.etype.startswith("a-") and e.uid is not None:
                key = ("a", e.uid)
                if key in seen:
                    self.dropped += 1
                    continue
                seen.add(key)
            kept.appendleft(e)
        if len(kept) != len(self.q):
            self.q = kept
            self.bytes = sum(len(e.body) for e in self.q)
        # 2. drop the oldest
        while self.q and (len(self.q) > self.max_entries or self.bytes > self.max_bytes):
            e = self.q.popleft(); self.bytes -= len(e.body); self.dropped += 1


class Broker:
    def __init__(self, loop, host: str, user: str, password: str, ttl_ms: str,
                 on_state: Callable[[bool], None] | None = None):
        self.loop = loop
        self.params = pika.ConnectionParameters(
            host=host, credentials=pika.PlainCredentials(user, password), heartbeat=60,
            blocked_connection_timeout=None, connection_attempts=1, socket_timeout=10,
            client_properties={"connection_name": "batman-eud-gateway"})
        self.ttl = ttl_ms
        self.on_state = on_state
        self.conn: AsyncioConnection | None = None
        self.pub = None                 # the publishing channel
        self.open = False               # publishing channel usable
        self.blocked = False
        self.down_since: float | None = time.monotonic()
        self._backoff_i = 0
        self._closing = False
        self._seq = 0                   # publish sequence on the pub channel (broker numbering)
        self._unacked: dict[int, tuple[SessionCache, CacheEntry]] = {}
        self.caches: set[SessionCache] = set()
        self.devices: dict[str, "DeviceChannel"] = {}
        self.stats = collections.Counter()
        self._retry_handle = None

    # -- lifecycle -------------------------------------------------------------------------------
    def start(self) -> None:
        # the AMQP-down clock starts when we first try the broker, not when the object was built (the start
        # sequence may have waited minutes for the schema before, C2B-2)
        self.down_since = time.monotonic()
        self._connect()

    def _connect(self) -> None:
        if self._closing:
            return
        log.info("AMQP connecting to %s", self.params.host)
        self.conn = AsyncioConnection(self.params, on_open_callback=self._on_conn_open,
                                      on_open_error_callback=self._on_conn_error,
                                      on_close_callback=self._on_conn_closed, custom_ioloop=self.loop)

    def _schedule_reconnect(self) -> None:
        if self._closing:
            return
        d = BACKOFF[min(self._backoff_i, len(BACKOFF) - 1)] * random.uniform(0.75, 1.25)
        self._backoff_i += 1
        log.warning("AMQP lost: reconnecting in %.1f s", d)
        self.loop.call_later(d, self._connect)

    def _on_conn_error(self, conn, err) -> None:
        log.warning("AMQP open error: %s", err)
        self._schedule_reconnect()

    def _on_conn_closed(self, conn, reason) -> None:
        was_open = self.open
        self.open = False
        self.pub = None
        if self.down_since is None:
            self.down_since = time.monotonic()
        self._requeue_unacked()
        for d in list(self.devices.values()):
            d.on_connection_lost()
        if was_open and self.on_state:
            self.on_state(False)
        if not self._closing:
            log.warning("AMQP connection closed: %s", reason)
            self._schedule_reconnect()

    def _on_conn_open(self, conn) -> None:
        conn.add_on_connection_blocked_callback(self._on_blocked)
        conn.add_on_connection_unblocked_callback(self._on_unblocked)
        conn.channel(on_open_callback=self._on_pub_open)

    def _on_blocked(self, conn, frame) -> None:
        self.blocked = True
        log.warning("AMQP blocked by the broker (memory alarm): caching")

    def _on_unblocked(self, conn, frame) -> None:
        self.blocked = False
        log.info("AMQP unblocked")
        self.flush_all()

    def _on_pub_open(self, ch) -> None:
        self.pub = ch
        ch.add_on_close_callback(self._on_pub_closed)
        ch.add_on_return_callback(self._on_return)
        # declare everything the gateway uses, with the producers' exact arguments
        pending = [len(EXCHANGES) + 2]

        def done(_f=None):
            pending[0] -= 1
            if pending[0] == 0:
                ch.confirm_delivery(ack_nack_callback=self._on_ack, callback=self._on_confirm_ok)
        for name, typ, dur in EXCHANGES:
            ch.exchange_declare(exchange=name, exchange_type=typ, durable=dur, callback=done)
        ch.queue_declare(queue="cot_parser", callback=done)
        ch.queue_bind(queue="cot_parser", exchange="cot_parser", routing_key="cot_parser", callback=done)

    def _on_confirm_ok(self, _frame) -> None:
        self._seq = 0
        self._unacked.clear()
        self.open = True
        self.down_since = None
        self._backoff_i = 0
        log.info("AMQP open")
        if self.on_state:
            self.on_state(True)
        for d in list(self.devices.values()):
            d.place()
        self.flush_all()

    def _on_pub_closed(self, ch, reason) -> None:
        if ch is not self.pub:
            return
        log.warning("AMQP publishing channel closed: %s", reason)
        self.open = False
        self.pub = None
        self._requeue_unacked()
        if self.conn is not None and self.conn.is_open and not self._closing:
            self.conn.channel(on_open_callback=self._on_pub_open)

    def close(self) -> None:
        self._closing = True
        try:
            if self.conn is not None and not self.conn.is_closed:
                self.conn.close()
        except Exception:
            pass

    # -- publishing (M6) -------------------------------------------------------------------------
    def register(self, cache: SessionCache) -> None:
        self.caches.add(cache)

    def unregister(self, cache: SessionCache) -> None:
        self.caches.discard(cache)

    def publish_cot(self, cache: SessionCache, uid: str | None, etype: str, body: bytes) -> None:
        """Queue a cot_parser body for at-least-once delivery, in order behind the session's cache."""
        cache.push_tail(CacheEntry(uid, etype, body))
        self._flush(cache)

    def publish_aux(self, exchange: str, body: bytes) -> bool:
        """firehose / flask-socketio: fire-and-forget (confirmed, never retried, never mandatory)."""
        if not self.open or self.blocked or self.pub is None:
            self.stats["aux_dropped"] += 1
            return False
        try:
            self.pub.basic_publish(exchange=exchange, routing_key="", body=body,
                                   properties=pika.BasicProperties(expiration=self.ttl))
            self._seq += 1
            return True
        except Exception as e:
            log.warning("aux publish to %s failed: %s", exchange, e)
            return False

    def flush_all(self) -> None:
        for c in list(self.caches):
            self._flush(c)

    def _flush(self, cache: SessionCache) -> None:
        if not self.open or self.blocked or self.pub is None or cache.hold:
            return
        now = time.monotonic()
        while cache.q:
            head = cache.q[0]
            if head.returned and cache.inflight > 0:
                return                      # a retry waits for the in-flight ones first
            if cache.retry_at > now:
                self._arm_retry(cache)
                return
            e = cache.pop_head()
            try:
                self.pub.basic_publish(exchange="cot_parser", routing_key="cot_parser", body=e.body,
                                       properties=pika.BasicProperties(expiration=self.ttl), mandatory=True)
            except Exception as ex:
                log.warning("publish failed: %s", ex)
                cache.push_head(e)
                return
            self._seq += 1
            self._unacked[self._seq] = (cache, e)
            cache.inflight += 1
            if e.returned:
                e.returned = False
                return                      # head-only retry: the rest waits for its ack

    def _arm_retry(self, cache: SessionCache) -> None:
        if cache.retry_armed:
            return
        cache.retry_armed = True
        delay = max(0.0, cache.retry_at - time.monotonic())

        def fire():
            cache.retry_armed = False
            self._flush(cache)
        self.loop.call_later(delay + 0.01, fire)

    def _on_ack(self, frame) -> None:
        m = frame.method
        tags = ([t for t in list(self._unacked) if t <= m.delivery_tag] if m.multiple else [m.delivery_tag])
        is_nack = m.NAME.endswith("Nack")
        for t in tags:
            item = self._unacked.pop(t, None)
            if item is None:
                continue
            cache, e = item
            cache.inflight = max(0, cache.inflight - 1)
            if is_nack:
                self.stats["nacked"] += 1
                e.returned = True
                cache.push_head(e)
                cache.retry_n += 1           # a nack is retried with the same backoff as a return (C1A-8)
                cache.retry_at = time.monotonic() + RETURN_BACKOFF[min(cache.retry_n, len(RETURN_BACKOFF)) - 1]
            elif e.returned:
                pass                         # returned then acked: already back in the cache
            else:
                self.stats["confirmed"] += 1
                cache.retry_n = 0
            if cache.q and (is_nack or not e.returned):
                self._flush(cache)
            elif cache.q and e.returned and cache.inflight == 0:
                self._arm_retry(cache)          # returned then acked: the head retry is scheduled, not waited for (C1A-6)
            elif cache.ending and not cache.q and cache.inflight == 0:
                self.caches.discard(cache)      # the device's goodbye is delivered: forget its cache

    def _on_return(self, ch, method, props, body) -> None:
        """A mandatory publish with no bound queue: back to the HEAD, retry with backoff."""
        self.stats["returned"] += 1
        for tag, (cache, e) in list(self._unacked.items()):
            if e.body == body and not e.returned:
                e.returned = True
                cache.push_head(e)
                cache.retry_n += 1
                cache.retry_at = time.monotonic() + RETURN_BACKOFF[min(cache.retry_n, len(RETURN_BACKOFF)) - 1]
                log.warning("cot_parser body returned (%s); retry in %d s", method.reply_text,
                            RETURN_BACKOFF[min(cache.retry_n, len(RETURN_BACKOFF)) - 1])
                self._arm_retry(cache)      # scheduled now: the ack that follows the return may be the last event (C1A-6)
                return
        log.warning("returned body matched no in-flight entry")

    def _requeue_unacked(self) -> None:
        """Connection/channel loss: every unacked body back to its cache head, in publish order."""
        for tag in sorted(self._unacked, reverse=True):
            cache, e = self._unacked.pop(tag)
            e.returned = False
            cache.push_head(e)
        for c in self.caches:
            c.inflight = 0

    # -- stats for the snapshot / stop ----------------------------------------------------------
    def inflight_total(self) -> int:
        return len(self._unacked)

    def cached_total(self) -> int:
        return sum(len(c) for c in self.caches)

    def cot_parser_ready(self, cb: Callable[[int | None], None]) -> None:
        """M13 step 4: READY messages in the cot_parser queue (passive declare), None if unavailable."""
        if not self.open or self.pub is None:
            cb(None); return
        try:
            self.pub.queue_declare(queue="cot_parser", passive=True,
                                   callback=lambda f: cb(f.method.message_count))
        except Exception:
            cb(None)

    # -- devices (M7) ----------------------------------------------------------------------------
    def device_channel(self, key: str, uid: str, callsign: str | None, on_delivery) -> "DeviceChannel":
        d = DeviceChannel(self, key, uid, callsign, on_delivery)
        self.devices[key] = d
        if self.open:
            d.place()
        return d

    def drop_device(self, key: str) -> None:
        d = self.devices.pop(key, None)
        if d is not None:
            d.close()


class DeviceChannel:
    """One AMQP channel + consumer(s) per device (M7); bindings reconciled from the DB (M9)."""

    def __init__(self, broker: Broker, key: str, uid: str, callsign: str | None, on_delivery):
        self.broker, self.key, self.uid, self.callsign = broker, key, uid, callsign
        self.on_delivery = on_delivery      # (bytes) -> bool  (True = enqueued -> ack)
        self.ch = None
        self.ready = False
        self.placed: set[tuple[str, str, str]] = set()
        self.needed: set[tuple[str, str, str]] = set()
        self.unbind_first: set[tuple[str, str, str]] = set()   # candidate set at identification (B2-13)
        self._consumer_tags: list[str] = []
        self._closed = False
        self._opening = None            # the Channel whose OpenOk is awaited: place() is idempotent meanwhile (C3B-1)
        self.replaces = 0
        self.delivered = 0

    def set_needed(self, needed: set[tuple[str, str, str]], unbind_candidates: set | None = None) -> None:
        self.needed = set(needed)
        if unbind_candidates:
            self.unbind_first = set(unbind_candidates) - self.needed
        if self.ready:
            self.reconcile()
        elif self.ch is None and not self._closed:
            self.place()                    # a channel closed by a 404/406 is re-placed on the next reconcile (C1A-3/C1B-4)

    def place(self) -> None:
        if self._closed or self.broker.conn is None or not self.broker.conn.is_open:
            return
        if self.ch is not None and self.ch.is_open:
            return
        if self._opening is not None:
            return                      # OpenOk pending (pika opens asynchronously): one channel per device (C3B-1)
        self.replaces += 1
        self._opening = True            # placeholder: pika may run _on_open synchronously (and a fake does)
        ch = self.broker.conn.channel(on_open_callback=self._on_open)
        if self._opening is True:
            self._opening = ch          # OpenOk still pending

    def _on_open(self, ch) -> None:
        self._opening = None
        if self._closed:                # the device ended before OpenOk: no declare/bind/consume for it (C3B-2)
            try:
                ch.close()
            except Exception:
                pass
            return
        self.ch = ch
        ch.add_on_close_callback(self._on_close)
        ch.basic_qos(prefetch_count=50, callback=lambda _f: self._declare())

    def _declare(self) -> None:
        ch = self.ch
        queues = [self.uid] + ([self.callsign] if self.callsign else [])
        pending = [len(queues)]

        def done(_f):
            pending[0] -= 1
            if pending[0] == 0:
                self.ready = True
                self.reconcile(then_consume=True)
        for q in queues:
            ch.queue_declare(queue=q, callback=done)

    def reconcile(self, then_consume: bool = False) -> None:
        """bind needed − placed, unbind (placed ∪ unbind_first) − needed; log the delta."""
        if not self.ready or self.ch is None or not self.ch.is_open:
            return
        ch = self.ch
        to_bind = self.needed - self.placed
        to_unbind = (self.placed | self.unbind_first) - self.needed
        self.unbind_first = set()
        for ex, q, rk in to_bind:
            ch.queue_bind(queue=q, exchange=ex, routing_key=rk)
            self.placed.add((ex, q, rk))
        for ex, q, rk in to_unbind:
            ch.queue_unbind(queue=q, exchange=ex, routing_key=rk)
            self.placed.discard((ex, q, rk))
        if to_bind or to_unbind:
            log.info("rebind %s +%d -%d", self.uid, len(to_bind), len(to_unbind))
        if then_consume:
            self._consume()

    def _consume(self) -> None:
        ch = self.ch
        self._consumer_tags = [ch.basic_consume(queue=self.uid, on_message_callback=self._on_message, auto_ack=False)]
        if self.callsign:
            self._consumer_tags.append(
                ch.basic_consume(queue=self.callsign, on_message_callback=self._on_message, auto_ack=False))

    def _on_message(self, ch, method, props, body) -> None:
        self.delivered += 1
        if self.on_delivery(body):
            ch.basic_ack(delivery_tag=method.delivery_tag)
        else:                       # the session is gone: give it back
            ch.basic_nack(delivery_tag=method.delivery_tag, requeue=True)

    def _on_close(self, ch, reason) -> None:
        if ch is not self.ch:
            return
        self.ready = False
        self.ch = None
        self.placed = set()          # unknown after a channel error: re-placed on the next reconcile
        if not self._closed:
            log.warning("device channel %s closed: %s (re-placed on the next reconcile)", self.uid, reason)

    def on_connection_lost(self) -> None:
        self.ready = False
        self.ch = None
        self._opening = None            # its OpenOk will never come
        self.placed = set()

    def unbind_placed_and_close(self) -> None:
        """Device end: unbind only what this gateway placed, then close the channel."""
        if self.ch is not None and self.ch.is_open:
            for ex, q, rk in list(self.placed):
                try:
                    self.ch.queue_unbind(queue=q, exchange=ex, routing_key=rk)
                except Exception:
                    pass
        self.placed = set()
        self.close()

    def close(self) -> None:
        self._closed = True
        self.ready = False
        ch, self.ch = self.ch, None
        if ch is not None and ch.is_open:
            try:
                ch.close()
            except Exception:
                pass

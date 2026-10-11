"""Offline test of the PATCHED EudHandler's AMQP side (#264 R5/R9): mandatory publish + basic.return handling,
the cot_parser queue declare on its own channel, broker flow control, and the bounded body cache. The methods
are extracted verbatim (ast) from the patched file and run against a fake pika channel/ioloop; no broker.
Negative control: these methods do not exist upstream (the upstream behaviour they replace - dropping an
unroutable publish, caching parsed objects without bound - is measured by the node suites), so this file only
proves the patched logic; it is not a discriminating test against upstream."""
import ast, sys, textwrap, logging
import threading as _threading

src = open(sys.argv[1], encoding="utf-8").read()
mod = ast.parse(src)
cls = next(n for n in mod.body if isinstance(n, ast.ClassDef) and n.name == "EudHandler")
WANT = ["_publish_on_ioloop", "_on_decl_channel_open", "_on_decl_channel_close", "_declare_cot_parser", "_on_blocked",
        "_on_unblocked", "_cache", "_flush_cache", "_on_return", "_schedule_retry", "_retry_head", "_after_head",
        "_on_confirm", "_requeue_unacked", "_schedule_reconnect", "_reconnect", "on_close", "on_open_error"]


class FakeProps:
    def __init__(self, **kw): self.kw = kw; self.headers = kw.get("headers")


class FakePika:
    BasicProperties = FakeProps


import random as _random
g = {"pika": FakePika, "CACHE_MAX": 5, "CACHE_MAX_BYTES": 10 ** 9, "random": _random, "DRAIN_MAX_S": 60, "Channel": object,
     "SUBSCRIBE_RETRY_S": 15, "_prewarm_parent": lambda: None, "SHUT_RDWR": 2}
for name in WANT:
    fn = next(n for n in cls.body if isinstance(n, ast.FunctionDef) and n.name == name)
    exec(textwrap.dedent(ast.get_source_segment(src, fn)), g)


class Chan:
    def __init__(self, is_open=True): self.is_open = is_open; self.pubs = []; self.decls = []; self.cbs = []
    def basic_publish(self, **kw): self.pubs.append(kw)
    def exchange_declare(self, *a, **k): self.decls.append(("x", a, k))
    def queue_declare(self, **k): self.decls.append(("q", k))
    def queue_bind(self, **k): self.decls.append(("b", k))
    def add_on_close_callback(self, cb): self.cbs.append(cb)
    def add_on_return_callback(self, cb): self.cbs.append(cb)
    def confirm_delivery(self, cb): self.confirm = cb


class Loop:
    def __init__(self): self.timers = []
    def call_later(self, d, fn): h = (d, fn); self.timers.append(h); return h
    def remove_timeout(self, h): self.timers.remove(h)
    def fire(self):  # run the earliest timer
        d, fn = self.timers.pop(0); fn(); return d


class Conn:
    def __init__(self): self.is_open = True; self.ioloop = Loop(); self.opened = []
    def channel(self, on_open_callback): self.opened.append(on_open_callback)


class App:
    config = {"OTS_RABBITMQ_TTL": "86400000"}


class H:
    def __init__(self, chan_open=True):
        self.logger = logging.getLogger("t"); self.app = App(); self.uid = "U"
        self.rabbit_channel = Chan(chan_open); self.rabbit_connection = Conn()
        self.cached_messages = []; self._cache_bytes = 0; self._dropped = 0; self._blocked = False
        self._decl_channel = None; self._decl_refused = False; self._retry_n = 0; self._retry_timer = None
        self._head_returned = False; self._closed = False
        self._pub_seq = 0; self._unacked = {}; self._returned = set(); self._need_replay = False; self._sub_ops = None
        self._chan_errors = []; self._reconnect_n = 0; self._reconnect_timer = None; self._ioloop = self.rabbit_connection.ioloop
        self._drained = _threading.Event(); self.client_address = ("10.0.0.9", 1)
        self.on_connection_open = lambda c: None
        self.on_channel_open = lambda c: None
        self._subscribed = False; self._squat_logged = False
        self.callsign = "CS"
        self._sub_timer = None; self._ret_n = 0
        self._end_args = None; self._loop_dead = False


for name in WANT:
    setattr(H, name, g[name])

P = 0; F = 0
def ok(c, msg):
    global P, F
    P += c; F += (not c); print(("PASS" if c else "FAIL"), msg)

# 1 open channel: cot_parser publish is mandatory with uid/type headers; firehose is plain
h = H(); h._publish_on_ioloop("firehose", "", "fh"); h._publish_on_ioloop("cot_parser", "cot_parser", "cp", ("U", "a-f-G"))
ok(len(h.rabbit_channel.pubs) == 2 and h.rabbit_channel.pubs[1]["mandatory"] is True
   and h.rabbit_channel.pubs[1]["properties"].headers == {"x-b264-uid": "U", "x-b264-type": "a-f-G"}
   and "mandatory" not in h.rabbit_channel.pubs[0], "1 cot_parser publish is mandatory + headers; firehose plain")
# 2 closed channel: cot_parser bodies are cached in order, firehose dropped; open -> flush in order
h = H(chan_open=False)
for i in range(3): h._publish_on_ioloop("firehose", "", "fh%d" % i); h._publish_on_ioloop("cot_parser", "cot_parser", "cp%d" % i, ("U", "b"))
ok([b for b, m in h.cached_messages] == ["cp0", "cp1", "cp2"] and h._cache_bytes == 9 and not h.rabbit_channel.pubs, "2 closed channel: 3 bodies cached, firehose not")
h.rabbit_channel.is_open = True; h._flush_cache()
ok([p["body"] for p in h.rabbit_channel.pubs] == ["cp0", "cp1", "cp2"] and not h.cached_messages and h._cache_bytes == 0, "2 flush publishes them in order, cache empty")
# 3 flow control: blocked -> cache; unblocked -> flush
h = H(); h._on_blocked(None, None); h._publish_on_ioloop("cot_parser", "cot_parser", "x", None)
ok(h._blocked and h.cached_messages == [("x", None)] and not h.rabbit_channel.pubs, "3 blocked: cached, not published")
h._on_unblocked(None, None); ok(not h._blocked and [p["body"] for p in h.rabbit_channel.pubs] == ["x"], "3 unblocked: flushed")
# 4 declare channel: opened by _declare_cot_parser when absent; declares exactly cot_parser.py:90/91 + app.py exchanges
h = H(); h._declare_cot_parser()
ok(len(h.rabbit_connection.opened) == 1, "4 no declare channel yet -> one is opened")
dc = Chan(); h.rabbit_connection.opened[0](dc)
ok(h._decl_channel is dc and dc.decls == [("x", ("cot_parser",), {"durable": True, "exchange_type": "direct"}),
                                          ("x", ("firehose",), {"durable": True, "exchange_type": "fanout"}),
                                          ("q", {"queue": "cot_parser"}),
                                          ("b", {"exchange": "cot_parser", "queue": "cot_parser", "routing_key": "cot_parser"})],
   "4 declare channel: cot_parser exchange/queue/binding with the upstream arguments, nothing else")
# 5 refused declare: logged once, no reopen loop, publishing unaffected
h._on_decl_channel_close(dc, "406 PRECONDITION_FAILED"); h._declare_cot_parser(); h._declare_cot_parser()
ok(h._decl_refused and h._decl_channel is None and len(h.rabbit_connection.opened) == 1, "5 refused declare: no reopen, flagged once")
h._publish_on_ioloop("cot_parser", "cot_parser", "still", None); ok(h.rabbit_channel.pubs[-1]["body"] == "still", "5 publishing continues after a refused declare")
# 6 basic.return: body to the HEAD, re-declare, head-only retry with backoff, flush once a head is not returned
h = H(); dc = Chan(); h._decl_channel = dc
h._cache("older", ("U", "a-f")); h._on_return(None, None, FakeProps(headers={"x-b264-uid": "R", "x-b264-type": "a-f"}), b"ret")
ok([b for b, m in h.cached_messages] == ["ret", "older"] and h.cached_messages[0][1] == ("R", "a-f") and len(dc.decls) == 4
   and h.rabbit_connection.ioloop.timers and h.rabbit_connection.ioloop.timers[0][0] == 2, "6 return: head of cache, meta kept, re-declared, retry in 2 s")
d = h.rabbit_connection.ioloop.fire()   # _retry_head
ok(d == 2 and [p["body"] for p in h.rabbit_channel.pubs] == ["ret"] and [b for b, m in h.cached_messages] == ["older"]
   and h.rabbit_connection.ioloop.timers[0][0] == 1.0, "6 retry publishes the head only; 1 s check scheduled")
h._on_return(None, None, FakeProps(headers={"x-b264-uid": "R"}), b"ret")   # it came back again inside the window
d = h.rabbit_connection.ioloop.fire()   # _after_head
ok(d == 1.0 and h.rabbit_connection.ioloop.timers[0][0] == 4 and [b for b, m in h.cached_messages] == ["ret", "older"], "6 returned again: next single try in 4 s")
h.rabbit_connection.ioloop.fire()       # _retry_head again -> publishes "ret"
h.rabbit_connection.ioloop.fire()       # _after_head, not returned this time -> flush the rest
ok([p["body"] for p in h.rabbit_channel.pubs] == ["ret", "ret", "older"] and not h.cached_messages and h._retry_n == 0
   and not h.rabbit_connection.ioloop.timers, "6 head accepted: the rest flushed, backoff reset, no timers left")
# 7 bounds: count (CACHE_MAX=5): the oldest position report with a newer one for the same uid/type goes first
h = H(chan_open=False)
for i, (u, t) in enumerate([("A", "a-f"), ("B", "b-t"), ("A", "a-f"), ("C", "a-f"), ("D", "b-t"), ("E", "b-t")]):
    h._cache("m%d" % i, (u, t))
ok([b for b, m in h.cached_messages] == ["m1", "m2", "m3", "m4", "m5"] and h._dropped == 1, "7 over CACHE_MAX: the older A/a-f (m0) dropped, newer A kept")
h._cache("m6", ("F", "b-t"))
ok([b for b, m in h.cached_messages] == ["m2", "m3", "m4", "m5", "m6"] and h._dropped == 2, "7 no coalescable entry: the oldest (m1) dropped")
g["CACHE_MAX_BYTES"] = 10; h = H(chan_open=False)
for i in range(4): h._cache("abcd", ("U%d" % i, "x"))   # 16 bytes > 10
ok(len(h.cached_messages) == 2 and h._cache_bytes == 8 and h._dropped == 2, "7 byte bound: entries dropped until under CACHE_MAX_BYTES")
# 8 R7 session cap: refused only when the container's own cgroup has less than SESSION_RESERVE_MB left;
#   no cap when the cgroup files are unreadable or the limit is "max"
for fname in ("_cg_mem", "_before_fork"):
    fn = next(n for n in mod.body if isinstance(n, ast.FunctionDef) and n.name == fname)
    exec(textwrap.dedent(ast.get_source_segment(src, fn)), g)
fn = next(n for n in cls.body if isinstance(n, ast.FunctionDef) and n.name == "_session_allowed")
exec(textwrap.dedent(ast.get_source_segment(src, fn)), g)
setattr(H, "_session_allowed", g["_session_allowed"])
real_cg_mem = g["_cg_mem"]
r = real_cg_mem()
ok(r == (None, None) or (isinstance(r[0], int) and (r[1] is None or isinstance(r[1], int))), "8 _cg_mem on this host: ints or (None, None), never raises")
g["SESSION_RESERVE_MB"] = 40
h = H(); h.client_address = ("10.0.0.9", 1234)
g["_cg_mem"] = lambda: (400 << 20, 512 << 20); ok(h._session_allowed() is True, "8 112 MiB free >= 40 MiB reserve: session allowed")
g["_cg_mem"] = lambda: (480 << 20, 512 << 20); ok(h._session_allowed() is False, "8 32 MiB free < 40 MiB reserve: session refused")
g["_cg_mem"] = lambda: (472 << 20, 512 << 20); ok(h._session_allowed() is True, "8 exactly 40 MiB free: allowed (strict less-than)")
g["_cg_mem"] = lambda: (500 << 20, None); ok(h._session_allowed() is True, "8 memory.max = max (no limit): allowed")
g["_cg_mem"] = lambda: (None, None); ok(h._session_allowed() is True, "8 cgroup unreadable: allowed (no cap)")
import gc as _gc
g["gc"] = _gc; g["_before_fork"](); ok(_gc.get_freeze_count() > 0, "8 _before_fork freezes the heap"); _gc.unfreeze()
# 9 R6: keepalive options on the client socket; session end publishes the disconnect + unbinds only when no other
#   consumer of the <uid> queue is left (another live session of the same EUD keeps its bindings)
for fname in ("_keepalive", "_end_session"):
    fn = next(n for n in cls.body if isinstance(n, ast.FunctionDef) and n.name == fname)
    exec(textwrap.dedent(ast.get_source_segment(src, fn)), g)
    setattr(H, fname, g[fname])
import socket as _socket
g["socket_mod"] = _socket
for k in ("KEEPALIVE_IDLE", "KEEPALIVE_INTVL", "KEEPALIVE_CNT", "KEEPALIVE_USER_TIMEOUT_MS"):
    g[k] = {"KEEPALIVE_IDLE": 45, "KEEPALIVE_INTVL": 15, "KEEPALIVE_CNT": 4, "KEEPALIVE_USER_TIMEOUT_MS": 120000}[k]


class Sock:
    def __init__(self): self.opts = []
    def setsockopt(self, lvl, opt, val): self.opts.append((lvl, opt, val))


h = H(); s = Sock(); h._keepalive(s)
want = [(_socket.SOL_SOCKET, _socket.SO_KEEPALIVE, 1), (_socket.IPPROTO_TCP, getattr(_socket, "TCP_KEEPIDLE", -1), 45),
        (_socket.IPPROTO_TCP, getattr(_socket, "TCP_KEEPINTVL", -1), 15), (_socket.IPPROTO_TCP, getattr(_socket, "TCP_KEEPCNT", -1), 4),
        (_socket.IPPROTO_TCP, getattr(_socket, "TCP_USER_TIMEOUT", -1), 120000)]
if hasattr(_socket, "TCP_USER_TIMEOUT"):
    ok(s.opts == want, "9 keepalive: SO_KEEPALIVE + IDLE 45 / INTVL 15 / CNT 4 + USER_TIMEOUT 120 s set in order")
else:
    ok(s.opts[:1] == want[:1], "9 keepalive: SO_KEEPALIVE set (TCP_* names absent on this host: the rest is skipped, logged)")


class EndChan(Chan):
    def __init__(self, consumers_left, messages=0):
        super().__init__(); self.consumer_tags = ["ct1", "ct2"]; self.cancelled = []; self.closed = False; self.left = consumers_left; self.passive = []; self.deleted = []; self.messages = messages
    def basic_cancel(self, tag): self.cancelled.append(tag)
    def queue_declare(self, queue, passive=False, callback=None, **k):
        self.passive.append((queue, passive))
        class M: pass
        m = M(); m.method = M(); m.method.consumer_count = self.left; m.method.message_count = self.messages; m.method.queue = queue; callback(m)
    def queue_delete(self, queue, **k): self.deleted.append((queue, k))
    def close(self): self.closed = True


unbound = []
H.unbind_rabbitmq_queues = lambda self, uid, binds: unbound.append((uid, binds))
h = H(); h.callsign = "CS"; h._subscribed = True; h.rabbit_channel = EndChan(0); h._end_session("U", "disc", [{"q": 1}])
ok(h.rabbit_channel.cancelled == ["ct1", "ct2"] and h.rabbit_channel.passive == [("U", True), ("CS", True)] and [p["body"] for p in h.rabbit_channel.pubs] == ["disc"]
   and unbound == [("U", [{"q": 1}])] and h.rabbit_channel.closed, "9 last session of U: consumers cancelled, both queues checked, disconnect published, unbound, channel closed")
ok([d[0] for d in h.rabbit_channel.deleted] == ["U", "CS"] and all(d[1] == {"if_unused": True, "if_empty": True} for d in h.rabbit_channel.deleted), "9 (F3) idle empty queues U and CS deleted (if_unused, if_empty)")
unbound.clear(); h = H(); h.callsign = "CS"; h._subscribed = True; h.rabbit_channel = EndChan(0, messages=3); h._end_session("U", "disc", [])
ok(not h.rabbit_channel.deleted and [p["body"] for p in h.rabbit_channel.pubs] == ["disc"] and h.rabbit_channel.closed, "9 (F3) queues with messages are kept")
unbound.clear(); h = H(); h.callsign = "U"; h._subscribed = True; h.rabbit_channel = EndChan(0); h._end_session("U", "disc", [])
ok(h.rabbit_channel.passive == [("U", True)] and [d[0] for d in h.rabbit_channel.deleted] == ["U"], "9 callsign == uid: one queue, checked and deleted once")
unbound.clear(); h = H(); h.callsign = "CS"; h.rabbit_channel = EndChan(5); h._end_session("U", "disc", [])
ok(not h.rabbit_channel.passive and not h.rabbit_channel.deleted and [p["body"] for p in h.rabbit_channel.pubs] == ["disc"] and h.rabbit_channel.closed,
   "9 never subscribed (relay platform / refused name): no queue check, no delete, disconnect published (upstream path)")
unbound.clear(); h = H(); h._subscribed = True; h.rabbit_channel = EndChan(1); h._end_session("U", "disc", [{"q": 1}])
ok(h.rabbit_channel.cancelled == ["ct1", "ct2"] and not h.rabbit_channel.pubs and not unbound and h.rabbit_channel.closed,
   "9 another consumer of U is live: no disconnect, no unbind, channel still closed")
unbound.clear(); h = H(); h.rabbit_channel = EndChan(5); h._end_session(None, "disc", [])
ok(not h.rabbit_channel.passive and [p["body"] for p in h.rabbit_channel.pubs] == ["disc"] and unbound == [(None, [])] and h.rabbit_channel.closed,
   "9 never identified (uid None): upstream path, no declare")
# 10 R4b publisher confirms: every publish on the channel is numbered; cot_parser bodies are kept until their ack;
#    multiple-ack, nack -> re-cached at the head, a returned message's ack is not a delivery
class Fr:
    def __init__(self, name, tag, multiple=False):
        class M: pass
        self.method = M(); self.method.NAME = name; self.method.delivery_tag = tag; self.method.multiple = multiple
h = H(); h._publish_on_ioloop("firehose", "", "fh"); h._publish_on_ioloop("cot_parser", "cot_parser", "c1", ("U", "a-f"))
h._publish_on_ioloop("cot_parser", "cot_parser", "c2", ("U", "a-f")); h._publish_on_ioloop("cot_parser", "cot_parser", "c3", ("U", "b-m"))
ok(h._pub_seq == 4 and list(h._unacked) == [2, 3, 4], "10 publishes numbered 1..4 (firehose counted), cot_parser bodies 2,3,4 unacked")
h._on_confirm(Fr("Basic.Ack", 3, multiple=True))
ok(list(h._unacked) == [4] and not h.cached_messages, "10 multiple ack up to 3: 2 and 3 delivered, 4 still unacked")
h._on_confirm(Fr("Basic.Nack", 4))
ok(not h._unacked and [b for b, m in h.cached_messages] == ["c3"] and bool(h.rabbit_connection.ioloop.timers), "10 nack 4: body back at the cache head, retry scheduled")
h = H(); h._publish_on_ioloop("cot_parser", "cot_parser", "r1", ("U", "a-f")); h._publish_on_ioloop("cot_parser", "cot_parser", "r2", ("U", "a-f"))
h._on_return(None, None, FakeProps(headers={"x-b264-uid": "U", "x-b264-type": "a-f"}), b"r1")
ok(h._returned == {1} and [b for b, m in h.cached_messages] == ["r1"], "10 return of r1: marked, re-cached once")
h._on_confirm(Fr("Basic.Ack", 2, multiple=True))
ok(not h._unacked and not h._returned and [b for b, m in h.cached_messages] == ["r1"], "10 ack covering the returned r1 is not a delivery: cache unchanged, r2 delivered")
# 11 R4 reconnect: connection closed while the session lives -> unacked re-cached in order, reconnect scheduled with
#    backoff 1,2,4..30 on the SAME ioloop with the same parameters; closed session -> loop stopped instead
class FakeConn2(Conn):
    def __init__(self, *a, **k): super().__init__(); self.args = (a, k); self.params = "P"; self.is_open = False   # a connection object exists while closed/failed
    def close(self): self.is_open = False
g["pika"].SelectConnection = FakeConn2
h = H(); h.rabbit_connection = FakeConn2(); h._ioloop = h.rabbit_connection.ioloop; h.client_address = ("10.0.0.9", 1)
h._publish_on_ioloop("cot_parser", "cot_parser", "u1", None); h._publish_on_ioloop("cot_parser", "cot_parser", "u2", None)
h._cache("later", None)
h.on_close(h.rabbit_connection, "missed heartbeats")
ok([b for b, m in h.cached_messages] == ["u1", "u2", "later"] and not h._unacked and h.rabbit_channel is None and h._need_replay
   and h._reconnect_timer is not None and 0.75 <= h._ioloop.timers[-1][0] <= 1.25, "11 connection closed: unacked at the head in order, reconnect in ~1 s (jitter)")
h._ioloop.fire()   # _reconnect -> new SelectConnection on the same ioloop
ok(isinstance(h.rabbit_connection, FakeConn2) and h.rabbit_connection.args[1].get("custom_ioloop") is h._ioloop and h.rabbit_connection.args[0][0] == "P"
   and h._reconnect_timer is None, "11 reconnect: new connection with the same params on the same ioloop")
h.on_open_error(h.rabbit_connection, "refused"); h.on_open_error(h.rabbit_connection, "refused")
ok(h._reconnect_n == 2 and 1.5 <= h._ioloop.timers[-1][0] <= 2.5, "11 open error: next attempt in ~2 s (backoff), one timer at a time")
for i in range(6): h._ioloop.fire(); h.on_open_error(h.rabbit_connection, "refused")
ok(22.5 <= h._ioloop.timers[-1][0] <= 37.5, "11 backoff capped at 30 s (with jitter)")
h2 = H(); h2.rabbit_connection = FakeConn2(); h2._ioloop = h2.rabbit_connection.ioloop; h2._closed = True; stopped = []
h2._ioloop.stop = lambda: stopped.append(1); h2.rabbit_connection.ioloop.add_callback_threadsafe = lambda fn: fn()
h2.on_close(h2.rabbit_connection, "bye")
ok(stopped == [1] and h2._reconnect_timer is None, "11 session already closing: loop stopped, no reconnect")
# 12 R4b order and bound: a new body queues behind a non-empty cache (never ahead of older ones); with CACHE_MAX
#    publishes unconfirmed the next body is held and released by the ack; the head retry goes ahead (force)
h = H(); h._cache("old", None); h._publish_on_ioloop("cot_parser", "cot_parser", "new", None)
ok([b for b, m in h.cached_messages] == ["old", "new"] and not h.rabbit_channel.pubs, "12 something older cached: the new body queues behind it")
h = H()
for i in range(7): h._publish_on_ioloop("cot_parser", "cot_parser", "b%d" % i, None)
ok(len(h._unacked) == 5 and [b for b, m in h.cached_messages] == ["b5", "b6"], "12 CACHE_MAX (5) unconfirmed: b5, b6 held in the cache")
h._on_confirm(Fr("Basic.Ack", 2, multiple=True))
ok(len(h._unacked) == 5 and not h.cached_messages and [p["body"] for p in h.rabbit_channel.pubs][-2:] == ["b5", "b6"], "12 ack frees room: held bodies published in order")
h = H(); h._cache("h1", None); h._cache("h2", None); h._retry_head()
ok([p["body"] for p in h.rabbit_channel.pubs] == ["h1"] and [b for b, m in h.cached_messages] == ["h2"], "12 head retry publishes ahead of the rest (force)")
# 13 R4: three channel closes within 60 s end the session loudly instead of looping
for fname in ("on_channel_close",):
    fn = next(n for n in cls.body if isinstance(n, ast.FunctionDef) and n.name == fname)
    exec(textwrap.dedent(ast.get_source_segment(src, fn)), g); setattr(H, fname, g[fname])
import time as _time; g["time"] = _time
ended = []
H.close_connection = lambda self: ended.append(1)
h = H(); h.rabbit_connection = FakeConn2(); h.rabbit_connection.is_open = True; h._ioloop = h.rabbit_connection.ioloop; h.callsign = "C"
h._sub_ops = [("queue_declare", (), {"queue": "amq.x"})]
h.on_channel_close(h.rabbit_channel, "403"); h.on_channel_close(h.rabbit_channel, "403")
ok(len(h.rabbit_connection.opened) == 2 and h._need_replay and not ended, "13 two channel errors: channel reopened twice, subscription to be replayed")
h.on_channel_close(h.rabbit_channel, "403")
ok(ended == [1] and h._sub_ops is None and len(h.rabbit_connection.opened) == 2, "13 third error within 60 s: session ended, no further reopen")
# 14 R4b drain: the client leaves while the broker is away -> reconnect kept alive for the cache; after the channel
#    opens and flushes, the session ends; a closing session with nothing pending stops at once
h = H(chan_open=False); h.rabbit_connection = FakeConn2(); h._ioloop = h.rabbit_connection.ioloop; h._closed = True
h._cache("left-behind", None); h._end_args = ("U", "disc", []); h._schedule_reconnect()
ok(h._reconnect_timer is not None, "14 closing with a cached body: reconnect still scheduled (bounded drain)")
h._ioloop.fire(); ok(isinstance(h.rabbit_connection, FakeConn2) and h.rabbit_connection.args[1].get("custom_ioloop") is h._ioloop, "14 reconnect runs for the drain")
h2 = H(chan_open=False); h2.rabbit_connection = FakeConn2(); h2._ioloop = h2.rabbit_connection.ioloop; h2._closed = True
h2._schedule_reconnect(); ok(h2._reconnect_timer is None, "14 closing with nothing pending: no reconnect")
# 15 R10: client-supplied uid/callsign must be usable, non-system queue names
fn = next(n for n in mod.body if isinstance(n, ast.FunctionDef) and n.name == "_valid_name")
exec(textwrap.dedent(ast.get_source_segment(src, fn)), g)
g["RESERVED_NAMES"] = frozenset({"cot_parser", "dms", "chatrooms", "missions", "groups", "firehose", "flask-socketio", "meshtastic", "dmrcot"})
v = g["_valid_name"]
ok(v("ANDROID-abc123") and v("Alpha 1") and v("中文呼號") and v("a" * 255), "15 ordinary uids/callsigns (incl. UTF-8, 255 ASCII bytes) accepted")
ok(not v("") and not v(None) and not v("a" * 256) and not v("中" * 86), "15 empty / None / >255 bytes refused")
ok(not v("cot_parser") and not v("COT_PARSER") and not v("firehose") and not v("groups") and not v("flask-socketio"), "15 system queue/exchange names refused (any case)")
ok(not v("amq.x") and not v("AMQ.gen-1") and not v("evil" + chr(0)) and not v("a" + chr(10) + "b"), "15 amq.* prefix and non-printable characters refused")
# 16 R10: the subscription is made once per session, and not while another consumer holds the EUD's queue
fn = next(n for n in cls.body if isinstance(n, ast.FunctionDef) and n.name == "_subscribe")
exec(textwrap.dedent(ast.get_source_segment(src, fn)), g); setattr(H, "_subscribe", g["_subscribe"])
class SubChan(Chan):
    def __init__(self, consumers):
        super().__init__(); self.consumers = consumers; self.ops = []
    def queue_declare(self, queue, callback=None, **k):
        self.ops.append(("queue_declare", queue))
        class M: pass
        m = M(); m.method = M(); m.method.consumer_count = self.consumers.get(queue, 0); m.method.queue = queue
        if callback: callback(m)
    def queue_bind(self, **k): self.ops.append(("queue_bind", k["queue"]))
    def basic_consume(self, **k): self.ops.append(("basic_consume", k["queue"]))
OPS = [("queue_declare", (), {"queue": "CS"}), ("queue_declare", (), {"queue": "U"}), ("queue_bind", (), {"exchange": "dms", "queue": "U", "routing_key": "U"}),
       ("basic_consume", (), {"queue": "CS", "on_message_callback": None, "auto_ack": True}), ("basic_consume", (), {"queue": "U", "on_message_callback": None, "auto_ack": True})]
h = H(); h.rabbit_channel = SubChan({}); h.client_address = ("10.0.0.9", 1); h._subscribe(OPS)
ok([o[0] for o in h.rabbit_channel.ops] == ["queue_declare", "queue_declare", "queue_bind", "basic_consume", "basic_consume"] and h._subscribed, "16 nobody on the queues: declare, bind, consume")
h._subscribe(OPS); ok(len(h.rabbit_channel.ops) == 5, "16 a second identifying CoT does not subscribe again (no consumer accumulation)")
h = H(); h.rabbit_channel = SubChan({"U": 1}); h.client_address = ("10.0.0.9", 1); h._subscribe(OPS)
ok([o[0] for o in h.rabbit_channel.ops] == ["queue_declare", "queue_declare"] and not h._subscribed and h._squat_logged and h._sub_timer is not None and h._ioloop.timers[-1][0] == 15,
   "16 another consumer on U: declared only, no bind/consume, logged once, retry timer 15 s")
h._ioloop.fire(); ok(len(h.rabbit_channel.ops) == 4 and not h._subscribed and h._sub_timer is not None, "16 the timer retries while the other consumer is there, and re-arms")
h.rabbit_channel.consumers = {}; h._ioloop.fire(); ok(h._subscribed and h._sub_timer is None and h.rabbit_channel.ops[-1] == ("basic_consume", "U"), "16 the other consumer gone: the timer subscribes, no more timer")
h = H(); h.rabbit_channel = SubChan({"U": 1}); h.client_address = ("10.0.0.9", 1); h._need_replay = True; h._subscribe(OPS)
ok(h._subscribed and not h._need_replay and h.rabbit_channel.ops[-1] == ("basic_consume", "U"), "16 replay after a reconnect ignores the consumer count (our own old consumer)")
# 17 R4: after a reconnect the subscription really is replayed through on_channel_open (review A-F1 / B-2)
fn = next(n for n in cls.body if isinstance(n, ast.FunctionDef) and n.name == "on_channel_open")
exec(textwrap.dedent(ast.get_source_segment(src, fn)), g); setattr(H, "on_channel_open", g["on_channel_open"])
g["uuid"] = __import__("uuid"); g["json"] = __import__("json")
h = H(); h.rabbit_connection = FakeConn2(); h._ioloop = h.rabbit_connection.ioloop; h.eud = None; h._pending_ops = None
h._sub_ops = OPS; h._subscribed = True          # subscribed on the old channel
h.on_close(h.rabbit_connection, "missed heartbeats")   # connection lost -> _need_replay, _subscribed cleared
ok(h._need_replay and not h._subscribed, "17 connection lost: replay pending, subscription gone")
nc = SubChan({}); del h.on_channel_open; h.on_channel_open(nc)   # the real method, not the fake's stub
ok([o[0] for o in nc.ops] == ["queue_declare", "queue_declare", "queue_bind", "basic_consume", "basic_consume"] and h._subscribed and not h._need_replay,
   "17 new channel: declares, binds and consumes replayed; replay flag cleared")
# 18 R4: a channel closed because the connection dropped is not a channel error (review A-F8)
h = H(); h.rabbit_connection = FakeConn2(); h.rabbit_connection.is_open = False; h._ioloop = h.rabbit_connection.ioloop; h.callsign = "C"
h.on_channel_close(None, "connection lost"); h.on_channel_close(None, "x"); h.on_channel_close(None, "x")
ok(not h._chan_errors and not ended[1:] and h.rabbit_channel is None and not h._subscribed, "18 three channel closes with the connection down: nothing counted, nothing reopened")
# 19 R4b order: returns of one burst and a multiple nack keep their order at the cache head (review A-F11 / B-9)
h = H(); h._cache("later", None)
for b in (b"r1", b"r2", b"r3"): h._on_return(None, None, FakeProps(headers={}), b)
ok([b for b, m in h.cached_messages] == ["r1", "r2", "r3", "later"], "19 three returns keep their order ahead of the older cache")
h = H()
for i in range(3): h._publish_on_ioloop("cot_parser", "cot_parser", "n%d" % i, None)
h._on_confirm(Fr("Basic.Nack", 3, multiple=True))
ok([b for b, m in h.cached_messages] == ["n0", "n1", "n2"], "19 a multiple nack re-caches in publish order")
# 20 R7 cap reads anonymous memory, not memory.current (review B-6): stubbed through _cg_mem in case 8 already;
#    here only that the real reader never raises
r = real_cg_mem(); ok(r == (None, None) or isinstance(r[0], int), "20 _cg_mem (memory.stat anon) never raises")
print("ALL PASS" if F == 0 else "SOME FAILED (%d)" % F)

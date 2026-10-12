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
        "_on_confirm", "_requeue_unacked", "_schedule_reconnect", "_reconnect", "on_close", "on_open_error",
        "_begin_end", "_try_end", "_finish_end", "_end_timeout", "_done", "_wait_end", "close_connection", "_admit"]


class FakeProps:
    def __init__(self, **kw): self.kw = kw; self.headers = kw.get("headers")


class FakePika:
    BasicProperties = FakeProps


import random as _random
g = {"pika": FakePika, "CACHE_MAX": 5, "CACHE_MAX_BYTES": 10 ** 9, "random": _random, "DRAIN_MAX_S": 60, "Channel": object,
     "_prewarm_parent": lambda: None, "SHUT_RDWR": 2, "json": __import__("json"), "threading": _threading,
     "PER_IP_MAX": 8}
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
    def __init__(self): self.is_open = True; self.is_closed = False; self.ioloop = Loop(); self.opened = []
    def channel(self, on_open_callback): self.opened.append(on_open_callback)


class App:
    config = {"OTS_RABBITMQ_TTL": "86400000"}


class _Req:
    def __init__(self): self.calls = []
    def shutdown(self, how): self.calls.append("shutdown")
    def close(self): self.calls.append("close")


class H:
    def _io(self, fn, *a): fn(*a); return True   # the ioloop thread, inline
    def __init__(self, chan_open=True):
        self.logger = logging.getLogger("t"); self.app = App(); self.uid = "U"
        self.rabbit_channel = Chan(chan_open); self.rabbit_connection = Conn()
        self.cached_messages = []; self._cache_bytes = 0; self._dropped = 0; self._blocked = False
        self._decl_channel = None; self._decl_refused = False; self._retry_n = 0; self._retry_timer = None
        self._head_returned = False; self._closed = False
        self._pub_seq = 0; self._unacked = {}; self._returned = set(); self._need_replay = False; self._sub_ops = None
        self._chan_errors = []; self._reconnect_n = 0; self._reconnect_timer = None; self._ioloop = self.rabbit_connection.ioloop
        self._end_done = _threading.Event(); self.client_address = ("10.0.0.9", 1)
        self.on_connection_open = lambda c: None
        self.on_channel_open = lambda c: None
        self._subscribed = False; self._squat_logged = False
        self.callsign = "CS"
        self._ret_n = 0
        self._end_args = None; self._loop_dead = False
        self._close_lock = _threading.Lock(); self._final_close = False; self._end_deadline = None
        self._sub_binds = []; self._sub_binds_pending = []; self._relay = False; self.user = None
        self.iothread = None; self.shutdown = False; self._pending_ops = None; self._chan_opening = False
        self._admit_fd = None; self._admit_mx = _threading.Lock(); self.request = _Req(); self.eud = None


for name in WANT:
    setattr(H, name, g[name])

P = 0; F = 0
def ok(c, msg):
    global P, F
    c = bool(c)
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
    # per-queue (consumers, messages) as the broker's passive DeclareOk reports them AFTER our own cancels
    def __init__(self, counts=None):
        super().__init__(); self.consumer_tags = ["ct1", "ct2"]; self.cancelled = []; self.closed = False; self.counts = counts or {}; self.passive = []; self.deleted = []
    def basic_cancel(self, tag): self.cancelled.append(tag)
    def queue_declare(self, queue, passive=False, callback=None, **k):
        self.passive.append((queue, passive))
        class M: pass
        c, n = self.counts.get(queue, (0, 0))
        m = M(); m.method = M(); m.method.consumer_count = c; m.method.message_count = n; m.method.queue = queue; callback(m)
    def queue_delete(self, queue, **k): self.deleted.append((queue, k))
    def close(self): self.closed = True


BU = {"exchange": "dms", "routing_key": "U", "queue": "U"}; BC = {"exchange": "dms", "routing_key": "CS", "queue": "CS"}
BG = {"exchange": "groups", "routing_key": "__ANON__.OUT", "queue": "U"}
unbound = []
H.unbind_rabbitmq_queues = lambda self, uid, binds: unbound.append((uid, binds))
def endh(counts=None, binds=(BU, BC, BG), callsign="CS", user=None, relay=False):
    unbound.clear(); h = H(); h.callsign = callsign; h._sub_binds = list(binds); h.user = user; h._relay = relay
    h.rabbit_channel = EndChan(counts); return h
h = endh(); h._end_session("U", "disc")
ok(h.rabbit_channel.cancelled == ["ct1", "ct2"] and h.rabbit_channel.passive == [("U", True), ("CS", True)] and [p["body"] for p in h.rabbit_channel.pubs] == ["disc"]
   and unbound == [("U", [BU, BC, BG])] and h.rabbit_channel.closed and h._final_close, "9 last session of U (8088): cancelled, both checked, disconnect, all its bindings unbound, final close")
ok([d[0] for d in h.rabbit_channel.deleted] == ["CS", "U"] and all(d[1] == {"if_unused": True, "if_empty": True} for d in h.rabbit_channel.deleted),
   "9 (F3) idle empty queues deleted (if_unused, if_empty), the <uid> queue LAST (a 406 on it must not cost the callsign queue)")
h = endh({"U": (0, 3)}); h._end_session("U", "disc")
ok([d[0] for d in h.rabbit_channel.deleted] == ["CS"] and [p["body"] for p in h.rabbit_channel.pubs] == ["disc"], "9 (F3) the <uid> queue holding messages is kept, the empty callsign queue goes")
h = endh(callsign="U", binds=(BU, BG)); h._end_session("U", "disc")
ok(h.rabbit_channel.passive == [("U", True)] and [d[0] for d in h.rabbit_channel.deleted] == ["U"], "9 callsign == uid: one queue, checked and deleted once")
h = endh(binds=()); h._end_session("U", "disc")
ok(not h.rabbit_channel.passive and not h.rabbit_channel.deleted and not h.rabbit_channel.pubs and not unbound and h.rabbit_channel.closed,
   "9 (r2 B2-1) never subscribed (refused name/owner): no check, no disconnect, NO unbind of the live session's bindings, no delete")
h = endh(binds=(), relay=True); h._end_session("U", "disc")
ok([p["body"] for p in h.rabbit_channel.pubs] == ["disc"] and not unbound and not h.rabbit_channel.passive, "9 relay platform (no queues): upstream's disconnect, nothing unbound")
h = endh(binds=()); h._end_session(None, "disc")
ok([p["body"] for p in h.rabbit_channel.pubs] == ["disc"] and not unbound and h.rabbit_channel.closed, "9 never identified (uid None): upstream's disconnect, no declare")
h = endh({"U": (1, 0)}); h._end_session("U", "disc")
ok(h.rabbit_channel.cancelled == ["ct1", "ct2"] and not h.rabbit_channel.pubs and not unbound and not h.rabbit_channel.deleted and h.rabbit_channel.closed,
   "9 (r2 A2-3) another consumer of U is live (the reconnected phone): no disconnect, no unbind, no delete")
h = endh({"CS": (1, 0)}); h._end_session("U", "disc")
ok([p["body"] for p in h.rabbit_channel.pubs] == ["disc"] and unbound == [("U", [BU, BG])] and [d[0] for d in h.rabbit_channel.deleted] == ["U"],
   "9 (r2 B2-4) another device shares the callsign: disconnect for U, U's bindings unbound, the callsign binding and queue kept")
h = endh(user=object()); h._end_session("U", "disc")
ok([p["body"] for p in h.rabbit_channel.pubs] == ["disc"] and unbound and not h.rabbit_channel.deleted,
   "9 (r2 A2-1) an authenticated (8089) session's queues are never deleted (cot_parser binds <uid> on its disconnect)")
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
# 11 R4/R13 (review r3 A3-3, the user's decision): the broker drops a LIVE session's connection -> the unacked bodies
#    go back to the cache in order, the CLIENT session ends (socket shut, the phone reconnects and is subscribed afresh
#    from the database), and the ioloop reconnects (backoff 1,2,4..30, same ioloop, same parameters) only to deliver
#    the cache before the goodbye; no second connection while one is opening (review r2 A2-9)
class FakeConn2(Conn):
    def __init__(self, *a, **k): super().__init__(); self.args = (a, k); self.params = "P"; self.is_open = False; self.is_closed = True
    def close(self): self.is_open = False; self.is_closed = True
g["pika"].SelectConnection = FakeConn2
ends11 = []
H._end_session = lambda self, uid, body: ends11.append(uid)
h = H(); h.rabbit_connection = FakeConn2(); h._ioloop = h.rabbit_connection.ioloop; h.client_address = ("10.0.0.9", 1)
h._publish_on_ioloop("cot_parser", "cot_parser", "u1", None); h._publish_on_ioloop("cot_parser", "cot_parser", "u2", None)
h._cache("later", None)
h.on_close(h.rabbit_connection, "missed heartbeats")
ok([b for b, m in h.cached_messages] == ["u1", "u2", "later"] and not h._unacked and h.rabbit_channel is None
   and h._closed and h._end_args is not None and h.request.calls[:1] == ["shutdown"] and not ends11
   and h._reconnect_timer is not None and any(0.75 <= t[0] <= 1.25 for t in h._ioloop.timers),
   "11 live connection lost: unacked back at the head in order, the client session ends, reconnect in ~1 s for the drain")
h._ioloop.timers = [t for t in h._ioloop.timers if t[1] == h._reconnect]
h._ioloop.fire()   # _reconnect -> new SelectConnection on the same ioloop
ok(isinstance(h.rabbit_connection, FakeConn2) and h.rabbit_connection.args[1].get("custom_ioloop") is h._ioloop and h.rabbit_connection.args[0][0] == "P"
   and h._reconnect_timer is None, "11 reconnect: new connection with the same params on the same ioloop")
h.rabbit_connection.is_closed = False   # opening: neither open nor closed
h._schedule_reconnect(); ok(h._reconnect_timer is None, "11 (r2 A2-9) a connection still opening: no second connection")
h.rabbit_connection.is_closed = True
h.on_open_error(h.rabbit_connection, "refused"); h.on_open_error(h.rabbit_connection, "refused")
ok(h._reconnect_n == 2 and 1.5 <= h._ioloop.timers[-1][0] <= 2.5, "11 open error during the drain: next attempt in ~2 s (backoff), one timer at a time")
for i in range(6): h._ioloop.timers = [t for t in h._ioloop.timers if t[1] == h._reconnect]; h._ioloop.fire(); h.on_open_error(h.rabbit_connection, "refused")
ok(22.5 <= h._ioloop.timers[-1][0] <= 37.5, "11 backoff capped at 30 s (with jitter)")
h.rabbit_connection.is_open = True; h.rabbit_connection.is_closed = False; h.rabbit_channel = Chan(); h._pub_seq = 0; h._try_end()
ok([p["body"] for p in h.rabbit_channel.pubs] == ["u1", "u2", "later"] and not ends11, "11 broker back: the cache is published, the end waits for the acks")
h._on_confirm(Fr("Basic.Ack", 3, multiple=True))
ok(ends11 == ["U"], "11 all acked: the session end (goodbye) runs")
h2 = H(); h2.rabbit_connection = FakeConn2(); h2._ioloop = h2.rabbit_connection.ioloop; h2._closed = True; stopped = []
h2._ioloop.stop = lambda: stopped.append(1); h2.rabbit_connection.ioloop.add_callback_threadsafe = lambda fn: fn()
h2.on_close(h2.rabbit_connection, "bye")
ok(stopped == [1] and h2._reconnect_timer is None, "11 session already ended: loop stopped, no reconnect")
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
real_close_connection = H.close_connection
H.close_connection = lambda self: (ended.append(1), setattr(self, "_closed", True))
h = H(); h.rabbit_connection = FakeConn2(); h.rabbit_connection.is_open = True; h.rabbit_connection.is_closed = False
h._ioloop = h.rabbit_connection.ioloop; h.callsign = "C"; h._sub_ops = [("queue_declare", (), {"queue": "amq.x"})]
h.on_channel_close(h.rabbit_channel, "403")
ok(ended == [1] and not h.rabbit_connection.opened and not h._need_replay,
   "13 (R13) a channel error on a LIVE session ends the client session (no reopen + replay any more)")
h._end_args = ("U", "disc")   # the end is draining
h.on_channel_close(None, "403"); h.on_channel_close(None, "403")
ok(h._end_done.is_set() and h._end_args is None, "13 three channel closes within 60 s while ending: the end completes at once (no drain over a failing channel)")
# 14 R4b/R6 end flow (review r2 A2-4/A2-6/A-F18): the end waits for its bodies to be ACKED, survives intermediate
#    channel/connection events, and only the end itself releases the handler
ends = []
g["CACHE_MAX_BYTES"] = 10 ** 9   # case 7 lowered it
H._end_session = lambda self, uid, body: ends.append((uid, body))
h = H(chan_open=False); h.rabbit_connection = FakeConn2(); h._ioloop = h.rabbit_connection.ioloop; h._closed = True
h._cache("left-behind", None); h._begin_end("U", "disc")
ok(h._reconnect_timer is not None and h._end_deadline is not None and not ends and not h._end_done.is_set(),
   "14 broker away at the end with a cached body: reconnect scheduled, deadline armed, handler not released")
h.on_channel_close(None, "x")   # an intermediate close must not release the handler (the old latch did)
ok(not h._end_done.is_set() and not ends, "14 (r2 A2-6) an intermediate channel close does not complete the end")
h.rabbit_channel = Chan(); h._try_end()
ok([p["body"] for p in h.rabbit_channel.pubs] == ["left-behind"] and not ends and bool(h._unacked), "14 channel back: the body is published, the end waits for its ack")
h._on_return(None, None, FakeProps(headers={}), b"left-behind")
h._on_confirm(Fr("Basic.Ack", 1))
ok(not ends and h.cached_messages and h._retry_timer is not None, "14 (A-F18) returned during the end: back in the cache, the end still waits")
h._ioloop.timers = [t for t in h._ioloop.timers if t[1] == h._retry_head]   # keep only the head retry
h._ioloop.fire(); h._on_confirm(Fr("Basic.Ack", 2)); h._ioloop.fire()
ok(ends == [("U", "disc")] and h._end_deadline is None, "14 head retried and acked: the end proceeds, the deadline is cancelled")
ends.clear(); h = H(); h._closed = True; h._begin_end("U", "disc")
ok(ends == [("U", "disc")], "14 nothing pending and an open channel: the end proceeds at once")
ends.clear(); h = H(); h._closed = True; h._cache("stuck", None); h._unacked = {1: ("x", None)}; h._begin_end("U", "disc")
dl = [t for t in h._ioloop.timers if t[1] == h._end_timeout]; ok(len(dl) == 1 and dl[0][0] == 60 and not ends, "14 unacked at the end: deadline DRAIN_MAX_S (60 s)")
h._ioloop.timers.remove(dl[0]); h._end_timeout()
ok(ends == [("U", "disc")], "14 deadline: disconnect/unbind anyway (the undelivered bodies are logged)")
h2 = H(chan_open=False); h2.rabbit_connection = FakeConn2(); h2._ioloop = h2.rabbit_connection.ioloop; h2._closed = True
h2._schedule_reconnect(); ok(h2._reconnect_timer is None, "14 closing with nothing pending and no end in progress: no reconnect")
h = H(); h._loop_dead = True; h.rabbit_channel = None; h.rabbit_connection = FakeConn2(); h._ioloop = h.rabbit_connection.ioloop
h._ioloop.stop = lambda: None; h._end_args = ("U", "disc"); h._try_end()
ok(h._end_done.is_set() and h._end_args is None, "14 loop dead: the end completes without the broker")
# 15 R10: client-supplied uid/callsign must be usable, non-system queue names
fn = next(n for n in mod.body if isinstance(n, ast.FunctionDef) and n.name == "_valid_name")
exec(textwrap.dedent(ast.get_source_segment(src, fn)), g)
g["RESERVED_NAMES"] = frozenset({"cot_parser", "dms", "chatrooms", "missions", "groups", "firehose", "flask-socketio", "meshtastic", "dmrcot"})
v = g["_valid_name"]
ok(v("ANDROID-abc123") and v("Alpha 1") and v("中文呼號") and v("a" * 255), "15 ordinary uids/callsigns (incl. UTF-8, 255 ASCII bytes) accepted")
ok(not v("") and not v(None) and not v("a" * 256) and not v("中" * 86), "15 empty / None / >255 bytes refused")
ok(not v("cot_parser") and not v("firehose") and not v("groups") and not v("flask-socketio"), "15 system queue/exchange names refused")
ok(v("COT_PARSER") and v("Missions"), "15 (r2 B2-3) other spellings are different queues (names are case-sensitive): a callsign 'Missions' is accepted")
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
FULL = ["queue_declare", "queue_declare", "queue_bind", "basic_consume", "basic_consume"]
h = H(); h.rabbit_channel = SubChan({}); h.client_address = ("10.0.0.9", 1); h._subscribe(OPS, [BU, BC])
ok([o[0] for o in h.rabbit_channel.ops] == FULL and h._subscribed and h._sub_binds == [BU, BC], "16 declare, bind, consume; the placed bindings recorded for the end")
h._subscribe(OPS); ok(len(h.rabbit_channel.ops) == 5, "16 a second identifying CoT does not subscribe again (no consumer accumulation)")
h = H(); h.rabbit_channel = SubChan({"U": 1, "CS": 1}); h.client_address = ("10.0.0.9", 1); h._subscribe(OPS, [BU, BC])
ok([o[0] for o in h.rabbit_channel.ops] == FULL and h._subscribed and not h._ioloop.timers,
   "16 (r2 B2-4/A2-3) another consumer on U/CS (stale session, same callsign): subscribed at once, shared as upstream, no retry timer")
h = H(); h.rabbit_channel = SubChan({}); h._closed = True; h._subscribe(OPS, [BU])
ok(not h.rabbit_channel.ops and not h._subscribed and not h._sub_binds, "16 an ended session does not subscribe")
h = H(); h.rabbit_channel = Chan(is_open=False); h._subscribe(OPS, [BU]); ok(h._pending_ops == OPS and not h._sub_binds, "16 channel not open yet: deferred, nothing recorded as placed")
h.rabbit_channel = SubChan({}); h._subscribe(h._pending_ops); ok(h._subscribed and h._sub_binds == [BU], "16 deferred subscription placed later with the bindings given first")
# 17 R13 (review r3 A3-3): a new channel never replays the recorded subscription (Marti-API bindings made after
#    identification were silently lost on replay); a live session that lost its connection ends instead
fn = next(n for n in cls.body if isinstance(n, ast.FunctionDef) and n.name == "on_channel_open")
exec(textwrap.dedent(ast.get_source_segment(src, fn)), g); setattr(H, "on_channel_open", g["on_channel_open"])
g["uuid"] = __import__("uuid"); g["json"] = __import__("json")
h = H(); h.rabbit_connection = FakeConn2(); h._ioloop = h.rabbit_connection.ioloop; h._pending_ops = None
h._sub_ops = OPS; h._subscribed = True; h._need_replay = True
nc = SubChan({}); del h.on_channel_open; h.on_channel_open(nc)
ok(not [o for o in nc.ops if o[0] in ("queue_declare", "queue_bind", "basic_consume")],
   "17 a new channel does not replay the recorded subscription (declare/bind/consume)")
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
# 21 R12 per-address count from this container's /proc/net/tcp(6): ESTABLISHED to our port from that address only
fn = next(n for n in mod.body if isinstance(n, ast.FunctionDef) and n.name == "_sessions_from")
exec(textwrap.dedent(ast.get_source_segment(src, fn)), g); g["struct"] = __import__("struct"); g["socket_mod"] = _socket
import io as _io
HDR = "  sl  local_address rem_address   st tx_queue rx_queue tr tm->when retrnsmt   uid  timeout inode\n"
def row(l, r, st): return f"   0: {l} {r} {st} 00000000:00000000 00:00000000 00000000     0        0 1\n"
TCP = HDR + row("0C0014AC:1F98", "20182A0A:C350", "01") + row("0C0014AC:1F98", "20182A0A:C351", "01") + row("0C0014AC:1F98", "20182A0A:C352", "06") \
    + row("0C0014AC:1F99", "20182A0A:C353", "01") + row("0C0014AC:1F98", "0A0F290A:C354", "01") + row("00000000:1F98", "00000000:0000", "0A")
TCP6 = HDR + row("00000000000000000000000000000000:1F98", "0000000000000000FFFF000020182A0A:C355", "01")
files = {"/proc/net/tcp": TCP, "/proc/net/tcp6": TCP6}
g["open"] = lambda p, *a, **k: _io.StringIO(files[p]) if p in files else (_ for _ in ()).throw(FileNotFoundError(p))
ok(g["_sessions_from"]("10.42.24.32", 8088) == 3, "21 10.42.24.32 -> :8088: 2 established (tcp) + 1 (v4-mapped tcp6); TIME_WAIT, other port, other host, listener not counted")
ok(g["_sessions_from"]("10.41.15.10", 8088) == 1 and g["_sessions_from"]("10.9.9.9", 8088) == 0, "21 other addresses counted separately")
files.clear(); ok(g["_sessions_from"]("10.42.24.32", 8088) == 0, "21 no /proc files: 0 (both absent)")
g["open"] = lambda *a, **k: (_ for _ in ()).throw(PermissionError("x")); ok(g["_sessions_from"]("10.42.24.32", 8088) is None, "21 unreadable: None (the caller logs, the memory reserve still applies)")
ok(g["_sessions_from"]("not-an-ip", 8088) is None, "21 a non-IPv4 client address: None, never raises"); del g["open"]
# 22 R12 admission (review r3 B3-2): the per-address count and the memory reserve FIRST (cheap, nothing allocated),
#    then the 8089 TLS handshake, then the admission lock and the memory reserve again (serialized)
for fname in ("_take_admit", "_release_admit"):
    fn = next(n for n in cls.body if isinstance(n, ast.FunctionDef) and n.name == fname)
    exec(textwrap.dedent(ast.get_source_segment(src, fn)), g); setattr(H, fname, g[fname])
import os as _os, fcntl as _fcntl, tempfile as _tf
g["os"] = _os; g["fcntl"] = _fcntl; g["time"] = __import__("time")
g["ADMIT_LOCK"] = _os.path.join(_tf.mkdtemp(), "admit.lock"); g["ADMIT_WAIT_S"] = 1; g["ADMIT_HOLD_S"] = 30
class TLS:
    def __init__(self, fail=False): self.fail = fail; self.calls = []
    def settimeout(self, t): self.calls.append(("timeout", t)); order.append(("timeout", t))
    def do_handshake(self):
        self.calls.append(("handshake",)); order.append("handshake")
        if self.fail: raise OSError("bad certificate")
class Srv: server_address = ("0.0.0.0", 8089)
order = []
H._session_allowed = lambda self: order.append("mem") or True
g["_sessions_from"] = lambda ip, port: order.append(("count", ip, port)) or 1
h = H(); h.is_ssl = True; h.request = TLS(); h.server = Srv(); h.client_address = ("10.42.24.32", 5)
ok(h._admit() is True and order == [("count", "10.42.24.32", 8089), "mem", ("timeout", 10), "handshake", ("timeout", None), "mem"]
   and h._admit_fd is not None, "22 8089: count, memory, handshake (10 s), then the lock and memory again; the lock is held")
h._release_admit(); ok(h._admit_fd is None, "22 the lock is released (after the first message, or ADMIT_HOLD_S)")
order.clear(); h = H(); h.is_ssl = True; h.request = TLS(fail=True); h.server = Srv()
ok(h._admit() is False and order[0][0] == "count" and order[1] == "mem" and "handshake" in order and order.count("mem") == 1 and h._admit_fd is None,
   "22 handshake fails: refused, the lock never taken")
order.clear(); g["_sessions_from"] = lambda ip, port: order.append("count") or 9; h = H(); h.is_ssl = True; h.request = TLS(); h.server = Srv()
ok(h._admit() is False and order == ["count"] and not h.request.calls, "22 9 sessions from the address (limit 8): refused before memory and before the handshake")
g["_sessions_from"] = lambda ip, port: 8; order.clear(); h = H(); h.is_ssl = False; h.request = TLS(); h.server = Srv()
ok(h._admit() is True and order == ["mem", "mem"] and not h.request.calls, "22 8088 with exactly 8: allowed, no handshake, memory checked twice"); h._release_admit()
order.clear(); g["_sessions_from"] = lambda ip, port: None; h = H(); h.is_ssl = False; h.request = TLS(); h.server = Srv()
ok(h._admit() is True and order == ["mem", "mem"], "22 count unreadable: only the memory reserve applies (logged)"); h._release_admit()
# 22b the lock serializes admissions: while one session holds it, the next waits (here ADMIT_WAIT_S 1 s, then it is
#     admitted unserialized and says so); a second memory refusal releases the lock at once
h1 = H(); h1.is_ssl = False; h1.request = TLS(); h1.server = Srv(); h1._admit()
import time as _t0
h2 = H(); h2.is_ssl = False; h2.request = TLS(); h2.server = Srv(); t0 = _t0.monotonic(); r = h2._admit(); dt = _t0.monotonic() - t0
ok(r is True and h1._admit_fd is not None and h2._admit_fd is None and dt >= 1.0, f"22b the lock is exclusive: the second admission waited {dt:.1f} s (ADMIT_WAIT_S), then went on unserialized")
h1._release_admit()
h3 = H(); h3.is_ssl = False; h3.request = TLS(); h3.server = Srv(); t0 = _t0.monotonic(); h3._admit(); dt = _t0.monotonic() - t0
ok(h3._admit_fd is not None and dt < 0.5, "22b released: the next admission takes the lock at once"); h3._release_admit()
seq = iter([True, False]); H._session_allowed = lambda self: next(seq)
h4 = H(); h4.is_ssl = False; h4.request = TLS(); h4.server = Srv()
ok(h4._admit() is False and h4._admit_fd is None, "22b refused by the second (serialized) memory check: the lock is released")
# 23 close_connection starts the end once, atomically, from either thread; _wait_end blocks until the END completes
H.close_connection = real_close_connection
queued = []
H._io = lambda self, fn, *a: queued.append((fn.__name__, a)) or True
class Req:
    def __init__(self): self.n = 0
    def shutdown(self, how): self.n += 1
    def close(self): self.n += 1
h = H(); h.request = Req(); h.uid = "U"
ts = [_threading.Thread(target=h.close_connection) for _ in range(8)]
[t.start() for t in ts]; [t.join() for t in ts]
ok(queued == [("_begin_end", ("U", '{"uid": "U", "cot": null, "disconnected": true, "user_id": null}'))] and h.shutdown and not h._end_done.is_set(),
   "23 (r2 A2-4) eight concurrent close_connection calls: the end is started exactly once, socket shut, end not yet complete")
h.iothread = _threading.Thread(target=lambda: None); done = []
w = _threading.Thread(target=lambda: (h._wait_end(), done.append(1))); w.start(); w.join(0.3)
ok(not done, "23 the handler thread waits while the end is in progress")
h._end_done.set(); w.join(2); ok(done == [1], "23 ... and is released when the end completes")
H._io = lambda self, fn, *a: False; h = H(); h.request = Req(); h.close_connection()
ok(h._end_done.is_set(), "23 no ioloop: the end is complete at once (nothing to drain)")
print("ALL PASS" if F == 0 else "SOME FAILED (%d)" % F)

"""Offline test of the PATCHED EudHandler's AMQP side (#264 R5/R9): mandatory publish + basic.return handling,
the cot_parser queue declare on its own channel, broker flow control, and the bounded body cache. The methods
are extracted verbatim (ast) from the patched file and run against a fake pika channel/ioloop; no broker.
Negative control: these methods do not exist upstream (the upstream behaviour they replace - dropping an
unroutable publish, caching parsed objects without bound - is measured by the node suites), so this file only
proves the patched logic; it is not a discriminating test against upstream."""
import ast, sys, textwrap, logging

src = open(sys.argv[1], encoding="utf-8").read()
mod = ast.parse(src)
cls = next(n for n in mod.body if isinstance(n, ast.ClassDef) and n.name == "EudHandler")
WANT = ["_publish_on_ioloop", "_on_decl_channel_open", "_on_decl_channel_close", "_declare_cot_parser", "_on_blocked",
        "_on_unblocked", "_cache", "_flush_cache", "_on_return", "_schedule_retry", "_retry_head", "_after_head"]


class FakeProps:
    def __init__(self, **kw): self.kw = kw; self.headers = kw.get("headers")


class FakePika:
    BasicProperties = FakeProps


g = {"pika": FakePika, "CACHE_MAX": 5, "CACHE_MAX_BYTES": 10 ** 9}
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
print("ALL PASS" if F == 0 else "SOME FAILED (%d)" % F)

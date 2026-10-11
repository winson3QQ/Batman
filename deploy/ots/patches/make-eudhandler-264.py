# SPDX-License-Identifier: GPL-3.0-or-later
# (contains verbatim fragments of OpenTAKServer 1.7.13 EudHandler.py as edit anchors)
"""Build the #264 stage-1 patched EudHandler.py for OpenTAKServer 1.7.13.

    make-eudhandler-264.py <upstream EudHandler.py> <out EudHandler-264.py>

Every edit asserts its exact upstream anchor, so any upstream drift fails loudly instead of producing a
half-applied file. The committed outputs are EudHandler-264.py (shipped, bind-mounted over the image's
file) and eudhandler-264.patch (= diff -u upstream -> EudHandler-264.py, kept for review/upstreaming);
check-eudhandler-264.sh proves both are exactly what this script makes from UPSTREAM_SHA256's file.
"""
import io, sys

src, dst = sys.argv[1], sys.argv[2]
s = io.open(src, encoding="utf-8").read()

def rep(old, new, count=1):
    global s
    n = s.count(old)
    assert n == count, f"anchor found {n}x (want {count}): {old[:70]!r}"
    s = s.replace(old, new)

# --- imports -------------------------------------------------------------------------------------
rep("import uuid\n", "import uuid\nimport functools  # BATMAN-264\nimport threading  # BATMAN-264\n")

# --- helpers (module level) ------------------------------------------------------------------------
rep("class EudHandler(socketserver.BaseRequestHandler):\n",
'''MAX_PENDING = 1 << 20  # BATMAN-264-PA: bytes held while waiting for a closing tag (upstream: unbounded)


class _OpRecorder:  # BATMAN-264: records channel calls made on the handler thread, replayed on the ioloop
    def __init__(self):
        self.ops = []

    def __getattr__(self, name):
        def rec(*a, **k):
            self.ops.append((name, a, k))
        return rec


class EudHandler(socketserver.BaseRequestHandler):
''')

# --- P-A: handle() ---------------------------------------------------------------------------------
OLD_HANDLE = '''    def handle(self):
        cot = ""

        while not self.shutdown:
            try:
                data = self.request.recv(65536)
            except Exception as e:
                self.logger.debug(f"recv failed: {e}")
                break
            if not data:
                self.logger.debug("no data")
                break

            cot += data.decode("utf-8")
            cot_list = re.split("</event>|</auth>", cot)

            if len(cot_list) < 2:
                continue

            for c in cot_list:
                try:
                    if "<event" in c:
                        fromstring(c + "</event>")
                        self.handle_cot(c + "</event>")
                    elif "<auth>" in c:
                        fromstring(c + "</auth>")
                        self.handle_auth(c + "</auth>")
                except ParseError as e:
                    self.logger.error(f"Failed to parse: {e}")
                    cot = c
                    break

            cot = ""

        self.close_connection()
'''
NEW_HANDLE = '''    def handle(self):
        # BATMAN-264-PA (#264 mechanism A): upstream split each recv on </event>, and when a recv ended inside a
        # message it saved the partial (cot = c) and then wiped it (cot = ""), so every message cut by a TCP
        # segment or a coalesced write was lost (measured 20-35 %). Keep raw BYTES until a closing tag is seen
        # (a multi-byte UTF-8 character split across recvs must not raise), decode only complete messages,
        # carry the remainder, and drop only a message that really is malformed.
        buf = b""
        scan = 0
        while not self.shutdown:
            try:
                data = self.request.recv(65536)
            except Exception as e:
                self.logger.debug(f"recv failed: {e}")
                break
            if not data:
                self.logger.debug("no data")
                break

            buf += data
            while not self.shutdown:
                ends = [(i, t) for i, t in ((buf.find(b"</event>", scan), b"</event>"),
                                            (buf.find(b"</auth>", scan), b"</auth>")) if i >= 0]
                if not ends:
                    scan = max(0, len(buf) - 8)  # resume near the end: no O(n^2) rescan of a slow sender
                    break
                end, tag = min(ends)
                end += len(tag)
                chunk, buf, scan = buf[:end], buf[end:], 0
                start = chunk.rfind(b"<event" if tag == b"</event>" else b"<auth>")
                if start < 0:
                    self.logger.error("Failed to parse: closing tag without an opening tag, dropped")
                    continue
                msg = chunk[start:].decode("utf-8", errors="replace")
                try:
                    fromstring(msg)
                    if tag == b"</event>":
                        self.handle_cot(msg)
                    else:
                        self.handle_auth(msg)
                except ParseError as e:
                    self.logger.error(f"Failed to parse: {e}")
            if len(buf) > MAX_PENDING:
                self.logger.error(f"{len(buf)} bytes without a closing tag from {self.client_address[0]}, dropped")
                buf, scan = b"", 0

        self.close_connection()
'''
rep(OLD_HANDLE, NEW_HANDLE)

# --- setup(): own ioloop entry, open-error callback, per-instance state ----------------------------------
rep('''    def setup(self):
        self.create_app()
''', '''    def setup(self):
        # BATMAN-264: per-instance state (upstream used class attributes) + ioloop liveness / drain signals
        self.cached_messages = []
        self.bound_queues = []
        self.group_memberships = []
        self._loop_dead = False
        self._closed = False
        self._pending_ops = None
        self._drained = threading.Event()
        self.create_app()
''')
rep('''                pika.ConnectionParameters(host=rabbit_host, credentials=rabbit_credentials),
                self.on_connection_open,
                on_close_callback=self.on_close,
            )''', '''                pika.ConnectionParameters(host=rabbit_host, credentials=rabbit_credentials),
                self.on_connection_open,
                on_open_error_callback=self.on_open_error,  # BATMAN-264: upstream had none -> ioloop died
                on_close_callback=self.on_close,
            )''')
rep('''            self.iothread = Thread(
                target=self.rabbit_connection.ioloop.start, name=f"IOLOOP_{self.common_name}"
            )''', '''            self.iothread = Thread(target=self._run, name=f"IOLOOP_{self.common_name}")  # BATMAN-264''')

# --- close_connection(): idempotent, all channel work on the ioloop, bounded drain ----------------------
OLD_CLOSE = '''    def close_connection(self):
        self.logger.info("{} disconnected".format(self.client_address[0]))

        self.rabbit_channel.basic_publish(
            exchange="cot_parser",
            body=json.dumps(
                {
                    "uid": self.uid,
                    "cot": None,
                    "disconnected": True,
                    "user_id": self.user.id if self.user else None,
                }
            ),
            routing_key="cot_parser",
            properties=pika.BasicProperties(expiration=self.app.config.get("OTS_RABBITMQ_TTL")),
        )

        self.unbind_rabbitmq_queues()

        if (
            self.rabbit_channel
            and not self.rabbit_channel.is_closing
            and not self.rabbit_channel.is_closed
        ):
            self.rabbit_channel.close()

        if not self.shutdown:
'''
NEW_CLOSE = '''    def close_connection(self):
        # BATMAN-264: idempotent (handle_auth and handle() could both call it); the disconnect publish, the
        # unbinds and channel.close() run on the ioloop thread (pika is not thread-safe); the handler waits
        # at most 2 s for the CloseOk so the last messages leave before the forked child os._exit()s.
        # Upstream published before checking the channel (ChannelWrongStateError, upstream #404).
        if self._closed:
            return
        self._closed = True
        self.logger.info("{} disconnected".format(self.client_address[0]))
        body = json.dumps(
            {
                "uid": self.uid,
                "cot": None,
                "disconnected": True,
                "user_id": self.user.id if self.user else None,
            }
        )
        binds = list(self.bound_queues)
        uid = self.uid

        def _close_on_ioloop():
            try:
                if self.rabbit_channel and self.rabbit_channel.is_open:
                    self.rabbit_channel.basic_publish(
                        exchange="cot_parser",
                        body=body,
                        routing_key="cot_parser",
                        properties=pika.BasicProperties(expiration=self.app.config.get("OTS_RABBITMQ_TTL")),
                    )
                    self.unbind_rabbitmq_queues(uid, binds)
                    self.rabbit_channel.close()  # on_channel_close (CloseOk) sets _drained
                else:
                    self._drained.set()
            except Exception as e:
                self.logger.error(f"close on ioloop failed: {e}")
                self._drained.set()

        if threading.current_thread() is self.iothread:
            _close_on_ioloop()  # called from on_message: never wait for ourselves
        elif self._io(_close_on_ioloop):
            self._drained.wait(2.0)

        if not self.shutdown:
'''
rep(OLD_CLOSE, NEW_CLOSE)

# --- on_channel_open: replay deferred subscriptions before cached messages ------------------------------
rep('''        for message in self.cached_messages:
            self.publish_cot(message)
''', '''        if self._pending_ops:  # BATMAN-264: a subscription requested before the channel was open
            ops, self._pending_ops = self._pending_ops, None
            self._subscribe(ops)

        for message in self.cached_messages:
            self.publish_cot(message)
''')

# --- on_channel_close / on_close: signal the drain; new callbacks + ioloop helpers ---------------------
rep('''    def on_channel_close(self, channel: Channel, error):
        self.logger.error(f"RabbitMQ channel closed for {self.callsign}, shut it down")
''', '''    def on_channel_close(self, channel: Channel, error):
        self.logger.error(f"RabbitMQ channel closed for {self.callsign}, shut it down")
        self._drained.set()  # BATMAN-264: CloseOk received -> earlier frames were sent
''')
rep('''    def on_close(self, connection, error):
        # Stop the ioloop using add_callback_threadsafe because ioloop.stop() isn't threadsafe
        connection.ioloop.add_callback_threadsafe(self.rabbit_connection.ioloop.stop)
        self.logger.info("Connection closed for {}: {}".format(self.client_address[0], error))
''', '''    def on_close(self, connection, error):
        # Stop the ioloop using add_callback_threadsafe because ioloop.stop() isn't threadsafe
        connection.ioloop.add_callback_threadsafe(self.rabbit_connection.ioloop.stop)
        self.logger.info("Connection closed for {}: {}".format(self.client_address[0], error))
        self._drained.set()  # BATMAN-264

    # ---- BATMAN-264: thread-safety helpers (stage 1; reconnect is stage 2) -------------------------------
    def _run(self):
        # Own ioloop entry: the handler must know when the loop is gone (a callback queued to a stopped loop
        # is silently never run), and a waiter must not hang on it.
        try:
            self.rabbit_connection.ioloop.start()
        except BaseException as e:
            self.logger.error(f"RabbitMQ ioloop ended with an error: {e}")
        finally:
            self._loop_dead = True
            self._drained.set()

    def on_open_error(self, connection, error):
        # Upstream passed no on_open_error_callback: pika's default raised inside the ioloop and killed it.
        self.logger.error(f"RabbitMQ connection failed for {self.client_address[0]}: {error}")
        self.shutdown = True
        connection.ioloop.stop()

    def _io(self, fn, *args):
        # Run fn on the ioloop thread. False = the loop is gone; the caller falls back to upstream's
        # "channel closed" behaviour. Never touches the channel from this (handler) thread.
        if threading.current_thread() is self.iothread:
            fn(*args)
            return True
        if self._loop_dead or not self.iothread or not self.iothread.is_alive():
            return False
        try:
            self.rabbit_connection.ioloop.add_callback_threadsafe(functools.partial(fn, *args))
            return True
        except Exception as e:
            self.logger.error(f"cannot hand work to the RabbitMQ ioloop: {e}")
            return False

    def _publish_on_ioloop(self, exchange, routing_key, body, event=None):
        if self.rabbit_channel and self.rabbit_channel.is_open:
            self.rabbit_channel.basic_publish(
                exchange=exchange,
                routing_key=routing_key,
                body=body,
                properties=pika.BasicProperties(expiration=self.app.config.get("OTS_RABBITMQ_TTL")),
            )
        elif event is not None and exchange == "cot_parser":
            self._cache(event)

    def _cache(self, event):
        if len(self.cached_messages) >= 1000:
            self.cached_messages.pop(0)
        self.cached_messages.append(event)
        self.logger.error("RabbitMQ channel is closed, not publishing cot")

    def _subscribe(self, ops):
        # replay queue_declare / queue_bind / basic_consume recorded by parse_device_info; if the channel is
        # not open yet (a client often sends its first CoT before AMQP is up), do it in on_channel_open
        # instead of never (upstream skipped the subscription for good)
        if self.rabbit_channel and self.rabbit_channel.is_open:
            for name, a, k in ops:
                getattr(self.rabbit_channel, name)(*a, **k)
        else:
            self._pending_ops = ops
''')

# --- publish_cot: bodies built on the handler thread, published on the ioloop --------------------------
OLD_PUB = '''        if not self.rabbit_channel or not self.rabbit_channel.is_open:
            self.cached_messages.append(event)
            self.logger.error("RabbitMQ channel is closed, not publishing cot")
            return

        # Route all CoTs to the firehose exchange for plugins and users that connect directly to RabbitMQ
        self.rabbit_channel.basic_publish(
            exchange="firehose",
            body=json.dumps({"uid": self.uid, "cot": str(event)}),
            routing_key="",
            properties=pika.BasicProperties(expiration=self.app.config.get("OTS_RABBITMQ_TTL")),
        )

        # Route all cots to the cot_parser direct exchange to be processed by a pool of cot_parser processes
        self.rabbit_channel.basic_publish(
            exchange="cot_parser",
            body=json.dumps(
                {"uid": self.uid, "cot": str(event), "user_id": self.user.id if self.user else None}
            ),
            routing_key="cot_parser",
            properties=pika.BasicProperties(expiration=self.app.config.get("OTS_RABBITMQ_TTL")),
        )
'''
NEW_PUB = '''        # BATMAN-264: bodies are built here (the DB-bound self.user is thread-local to this thread), the
        # publishes run on the ioloop thread. If the loop is gone: upstream's "channel closed" path.
        fh = json.dumps({"uid": self.uid, "cot": str(event)})
        cp = json.dumps({"uid": self.uid, "cot": str(event), "user_id": self.user.id if self.user else None})

        def _both():
            # Route all CoTs to the firehose exchange for plugins and users that connect directly to RabbitMQ
            self._publish_on_ioloop("firehose", "", fh)
            # Route all cots to the cot_parser direct exchange to be processed by a pool of cot_parser processes
            self._publish_on_ioloop("cot_parser", "cot_parser", cp, event)

        if not self._io(_both):
            self._cache(event)
'''
rep(OLD_PUB, NEW_PUB)

# --- parse_device_info: record the subscription calls, replay them on the ioloop ------------------------
rep('''                if (
                    self.rabbit_channel
                    and self.rabbit_channel.is_open
                    and platform != "OpenTAK ICU"''', '''                _ch = _OpRecorder()  # BATMAN-264: channel calls recorded here, run on the ioloop by _subscribe
                if (
                    platform != "OpenTAK ICU"''')
blk_start = s.index("_ch = _OpRecorder()")
blk_end = s.index('            if "phone" in contact.attrs and contact.attrs["phone"]:')
blk = s[blk_start:blk_end]
n_calls = blk.count("self.rabbit_channel.")
assert n_calls == 10, f"expected 10 channel calls in the subscription block, found {n_calls}"
blk = blk.replace("self.rabbit_channel.", "_ch.")
blk = blk.rstrip("\n") + "\n                if _ch.ops:\n                    self._io(self._subscribe, _ch.ops)\n\n"
s = s[:blk_start] + blk + s[blk_end:]

# --- EUD info to the web map: on the ioloop ------------------------------------------------------------
rep('''                    self.rabbit_channel.basic_publish(
                        exchange="flask-socketio",
                        routing_key="",
                        body=json.dumps(message).encode(),
                        properties=pika.BasicProperties(
                            expiration=self.app.config.get("OTS_RABBITMQ_TTL")
                        ),
                    )''', '''                    self._io(self._publish_on_ioloop, "flask-socketio", "", json.dumps(message).encode())  # BATMAN-264''')

# --- unbind: runs on the ioloop with a snapshot of the bindings -----------------------------------------
OLD_UNBIND = '''    def unbind_rabbitmq_queues(self):
        if (
            self.uid
            and self.rabbit_channel
            and not self.rabbit_channel.is_closing
            and not self.rabbit_channel.is_closed
        ):
            self.rabbit_channel.queue_unbind(
                queue=self.uid, exchange="missions", routing_key="missions"
            )
            self.rabbit_channel.queue_unbind(queue=self.uid, exchange="groups")

            for bind in self.bound_queues:'''
NEW_UNBIND = '''    def unbind_rabbitmq_queues(self, uid, binds):  # BATMAN-264: ioloop thread only, snapshot of the bindings
        if (
            uid
            and self.rabbit_channel
            and not self.rabbit_channel.is_closing
            and not self.rabbit_channel.is_closed
        ):
            self.rabbit_channel.queue_unbind(
                queue=uid, exchange="missions", routing_key="missions"
            )
            self.rabbit_channel.queue_unbind(queue=uid, exchange="groups")

            for bind in binds:'''
rep(OLD_UNBIND, NEW_UNBIND)

# --- license notice (GPL-3.0-or-later §5a: modified files carry a prominent dated notice) ----------
assert s.startswith("import base64\n"), "upstream file no longer starts with 'import base64'"
s = ("# SPDX-License-Identifier: GPL-3.0-or-later\n"
     "# OpenTAKServer 1.7.13 opentakserver/eud_handler/EudHandler.py, (c) the OpenTAKServer authors.\n"
     "# Modified by the Batman project for winson3QQ/Batman#264 on 2026-10-07 (every change is marked\n"
     "# BATMAN-264); see deploy/ots/patches/README.md. Distributed under the GNU GPL v3 or later.\n") + s

io.open(dst, "w", encoding="utf-8", newline="\n").write(s)
print("patched OK")

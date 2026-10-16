"""Listeners and the per-connection protocol (M1, M2, M3, M4, M5, M7, M8 hooks). asyncio.Protocol so that
`pause_reading()` (uplink back-pressure) and `pause_writing()` (downlink back-pressure) are available.
Every blocking DB call goes through `Gateway.db_call` (executor + timeout); the loop never blocks.
"""
from __future__ import annotations

import asyncio
import datetime as _dt
import logging
import socket
import time

from . import cot
from .amqp import SessionCache
from .bucket import TokenBucket
from .config import Settings, name_ok
from .framing import CarryOverflow, Framer
from .session import Conn, Device, Refused, Table

log = logging.getLogger("gateway.server")

SO_TCP_KEEPIDLE = getattr(socket, "TCP_KEEPIDLE", 4)
SO_TCP_KEEPINTVL = getattr(socket, "TCP_KEEPINTVL", 5)
SO_TCP_KEEPCNT = getattr(socket, "TCP_KEEPCNT", 6)
TCP_USER_TIMEOUT = 18   # linux


def _parse_start(s: str | None) -> _dt.datetime | None:
    if not s:
        return None
    try:
        return _dt.datetime.strptime(s[:19], "%Y-%m-%dT%H:%M:%S")
    except ValueError:
        return None


def set_socket_options(sock: socket.socket) -> None:
    """M11: keepalive 45/15/4 + TCP_USER_TIMEOUT 120 s; M7/M12: explicit 256 KiB buffers."""
    try:
        sock.setsockopt(socket.SOL_SOCKET, socket.SO_KEEPALIVE, 1)
        sock.setsockopt(socket.IPPROTO_TCP, SO_TCP_KEEPIDLE, 45)
        sock.setsockopt(socket.IPPROTO_TCP, SO_TCP_KEEPINTVL, 15)
        sock.setsockopt(socket.IPPROTO_TCP, SO_TCP_KEEPCNT, 4)
        sock.setsockopt(socket.IPPROTO_TCP, TCP_USER_TIMEOUT, 120_000)
        sock.setsockopt(socket.SOL_SOCKET, socket.SO_SNDBUF, 256 * 1024)
        sock.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 256 * 1024)
    except OSError as e:   # pragma: no cover - platform differences in tests
        log.debug("socket options: %s", e)


class Protocol(asyncio.Protocol):
    """One accepted connection (8088 or 8089)."""

    _next_cid = 1

    def __init__(self, gw: "Gateway", port: int):
        self.gw = gw
        self.port = port
        self.s: Settings = gw.s
        self.transport: asyncio.Transport | None = None
        self.conn: Conn | None = None
        self.framer = Framer(self.s.max_event_bytes, self.s.max_carry_bytes)
        self.can_write = asyncio.Event()
        self.can_write.set()
        self.paused_until = 0.0
        self._ident_task: asyncio.Task | None = None
        self._hs_task: asyncio.Task | None = None
        self._first_sa = None          # an identifying event that arrived before the cert lookup finished
        self._pre_ident: list = []     # CoT read between the first SA and the end of identification (C1A-4)
        self._early: list[bytes] = []  # app bytes delivered by sslproto before start_tls() returned (C2A-2)
        self._lost = False             # connection_lost ran (idempotent: also called by _handshake's exits, C2A-1)
        self._resume_handle = None
        self.tls_done = port != gw.s.tls_port   # 8088: no handshake; 8089: set by _handshake()

    # -- transport events --------------------------------------------------------------------
    def connection_made(self, transport) -> None:
        """Called at ACCEPT, before any TLS handshake (8089 listens raw and upgrades with start_tls, C1A-5/C1B-3):
        the pending pool and the memory reserve therefore cover pre-TLS sockets."""
        self.transport = transport
        peer = transport.get_extra_info("peername") or ("?", 0)
        cid = Protocol._next_cid; Protocol._next_cid += 1
        c = Conn(cid=cid, port=self.port, addr=str(peer[0]))
        c.write = self._write
        c.close = self.close
        c.pause = self._pause
        c.uplink = TokenBucket(self.s.uplink_bytes_per_s, self.s.uplink_bytes_per_s * 8)
        c.uplink_msgs = TokenBucket(self.s.uplink_msgs_per_s, self.s.uplink_msgs_per_s * 5)
        self.conn = c
        sock = transport.get_extra_info("socket")
        if sock is not None:
            set_socket_options(sock)
        transport.set_write_buffer_limits(high=256 * 1024, low=64 * 1024)
        try:
            self.gw.table.accept(c)
        except Refused as r:
            self.gw.log_refusal(f"refusing pending from {c.addr}: {r.reason}")
            self.close(r.reason)
            return
        self.gw.conns[cid] = self
        if self.port == self.s.tls_port:
            self._hs_task = self.gw.spawn(self._handshake(transport))

    async def _handshake(self, raw_transport) -> None:
        """8089: TLS over the accepted socket (M14 context, 10 s), then the cert lookup (M2.2)."""
        try:
            tls = await self.gw.loop.start_tls(raw_transport, self, self.gw.tls.ctx, server_side=True,
                                               ssl_handshake_timeout=self.s.handshake_s)
        except Exception as e:
            # a handshake that failed, timed out, or whose socket we aborted meanwhile (pool eviction, deadline):
            # sslproto never calls the app's connection_lost in the handshake state, so we do (C2A-1)
            c = self.conn
            if c is not None and not c.closed:
                self.gw.log_refusal(f"refusing cert from {c.addr}: handshake failed ({type(e).__name__}: {str(e)[:80]})")
                self.gw.stats["handshake_failed"] += 1
                c.close_reason = "handshake failed"
            # MEM-1: the exception's traceback references start_tls's frame, whose local waiter references the
            # exception again: a reference CYCLE that keeps the SSLProtocol and its 256 KiB _ssl_buffer alive until
            # a full GC (which the big buffers never trigger). 300 failed handshakes held ~90 MiB on 04; floods
            # kept adding. Breaking the cycle here frees them at once (refcount).
            e.__traceback__ = None
            del e
            try:
                raw_transport.abort()
            except Exception:
                pass
            self.connection_lost(None)
            return
        if tls is None or self.conn is None or self.conn.closed:
            self.connection_lost(None)
            return
        self.transport = tls
        tls.set_write_buffer_limits(high=256 * 1024, low=64 * 1024)
        self.tls_done = True
        if self._early:
            # sslproto delivers the app bytes that came with the client's Finished BEFORE start_tls() returns:
            # they were parked, process them now (C2A-2)
            early, self._early = self._early, []
            for chunk in early:
                self.data_received(chunk)
        await self._after_handshake()

    async def _after_handshake(self) -> None:
        """M2.2: the cert's CN must be an existing, active user (DB error -> close, not a refusal)."""
        c = self.conn
        cert = self.transport.get_extra_info("peercert") if self.transport else None
        cn = None
        for rdn in (cert or {}).get("subject", ()):
            for k, v in rdn:
                if k == "commonName":
                    cn = v
        if not cn:
            self.gw.log_refusal(f"refusing cert from {c.addr}: no CN")
            self.close("no CN"); return
        try:
            u = await self.gw.db_call(self.gw.db.user_by_name, cn)
        except Exception as e:
            log.warning("db error at the cert lookup for %s: %s", c.addr, e)
            self.close("db error"); return
        if u is None or not u[1]:
            self.gw.log_refusal(f"refusing cert CN={cn}: {'unknown user' if u is None else 'inactive user'}")
            self.close("cert user refused"); return
        c.user_id, c.username = u[0], cn
        self.gw.table.after_handshake(c)
        if self._first_sa is not None and c.device is None and not c.closed:
            ev, self._first_sa = self._first_sa, None
            self._ident_task = self.gw.spawn(self.gw.identify(self, c, ev))

    def data_received(self, data: bytes) -> None:
        c = self.conn
        if c is None or c.closed:
            return
        if not self.tls_done:
            # app bytes delivered by sslproto while start_tls() has not returned yet: park them (bounded), never
            # process them here (a pong would go out through the raw transport, in clear)
            if sum(len(b) for b in self._early) + len(data) <= self.s.max_carry_bytes:
                self._early.append(data)
            else:
                self.gw.stats["early_dropped"] += 1
            return
        now = time.monotonic()
        self.gw.table.note_rx(c, now)
        try:
            frames = self.framer.feed(data)
        except CarryOverflow:
            self.gw.log_limited("carry-over", f"carry-over over the bound from {c.addr}: closing", logging.WARNING)
            self.close("carry-over bound"); return
        # uplink rate: per session (bytes + messages), per user, global (M1)
        deficit = c.uplink.charge(len(data), now)
        nmsg = sum(1 for f in frames if f.kind in ("event", "auth"))
        if nmsg:
            deficit = max(deficit, c.uplink_msgs.charge(nmsg, now))
        if c.user_id is not None:
            deficit = max(deficit, self.gw.user_bucket(c.user_id).charge(len(data), now))
        deficit = max(deficit, self.gw.global_bucket.charge(len(data), now))
        if deficit > 0:
            self._pause(deficit)
        for f in frames:
            if f.kind == "oversize":
                self.gw.stats["oversize"] += 1
                self.gw.log_limited("oversize", f"oversize message from {self._who()}: {f.size} bytes, discarded",
                                    logging.WARNING)
                continue
            if f.kind == "junk":
                continue
            c.last_msg = now
            if f.kind == "auth":
                continue                      # answered by silence (the cert is the identity, M2.6)
            try:
                ev = cot.parse_event(f.data)
            except cot.Malformed as e:
                self.gw.stats["malformed"] += 1
                # one line per minute, not per message: a cert holder sending `<event/>` at 20/s for a day would
                # otherwise write GBs into the node's log volume (SEC-2); the count is in stats/snapshot
                self.gw.log_limited("malformed", f"malformed message from {self._who()} dropped: {e}")
                continue
            if ev.is_ping:
                self._write(cot.pong())
                continue
            if c.device is None:
                if self._ident_task is not None and not self._ident_task.done():
                    # identification in progress: keep what the phone sends meanwhile (bounded, C1A-4)
                    if len(self._pre_ident) < 64:
                        self._pre_ident.append(ev)
                    else:
                        self.gw.stats["pre_ident_dropped"] += 1
                    continue
                if self.port == self.s.tls_port and c.user_id is None:
                    # the cert lookup is still running: identify later with the FIRST SA, keep everything after it
                    # (a burst of reports in the first write must not lose all but one, C2B-5)
                    if self._first_sa is None:
                        if ev.identifies:
                            self._first_sa = ev
                    elif len(self._pre_ident) < 64:
                        self._pre_ident.append(ev)
                    else:
                        self.gw.stats["pre_ident_dropped"] += 1
                    continue
                if not ev.identifies:
                    continue
                self._ident_task = self.gw.spawn(self.gw.identify(self, c, ev))
                continue
            self.gw.uplink(c, ev)

    def take_pre_ident(self) -> list:
        evs, self._pre_ident = self._pre_ident, []
        return evs

    def pause_writing(self) -> None:
        self.can_write.clear()

    def resume_writing(self) -> None:
        self.can_write.set()

    def connection_lost(self, exc) -> None:
        c = self.conn
        if c is None or self._lost:
            return
        self._lost = True
        c.closed = True
        self.can_write.set()                  # a writer waiting on this socket must wake and re-check (C1B-1)
        self.gw.conns.pop(c.cid, None)
        # what the phone sent before its identification completed dies with the socket: counted, never silent (C3A-2)
        n = len(self._pre_ident) + (1 if self._first_sa is not None else 0)
        if n:
            self.gw.stats["pre_ident_dropped"] += n
            self._pre_ident, self._first_sa = [], None
            self.gw.log_limited("pre-ident-dropped", f"{n} message(s) from {c.addr} dropped: closed before identified")
        if self._resume_handle is not None:
            self._resume_handle.cancel()
        self.gw.on_connection_closed(c, c.close_reason or (str(exc) if exc else "peer closed"))

    # -- actions ---------------------------------------------------------------------------------
    def _who(self) -> str:
        c = self.conn
        return f"{c.device.uid if c and c.device else '-'}@{c.addr if c else '?'}"

    def _write(self, data: bytes) -> None:
        if self.transport is not None and not self.transport.is_closing():
            self.transport.write(data)

    def _pause(self, seconds: float) -> None:
        if self.transport is None or self.transport.is_closing():
            return
        until = time.monotonic() + min(seconds, 8.0)
        if until <= self.paused_until:
            return
        self.paused_until = until
        try:
            self.transport.pause_reading()
        except Exception:
            return
        self.gw.stats["uplink_paused"] += 1
        if self._resume_handle is not None:
            self._resume_handle.cancel()
        self._resume_handle = self.gw.loop.call_later(until - time.monotonic(), self._resume)

    def _resume(self) -> None:
        self.paused_until = 0.0
        if self.transport is not None and not self.transport.is_closing():
            try:
                self.transport.resume_reading()
            except Exception:
                pass

    def close(self, reason: str) -> None:
        """A forced close (refusal, deadline, excess connection, stop): abort(), never the graceful close()
        — a black-holed peer never acknowledges a FIN, so close() would keep the socket until
        TCP_USER_TIMEOUT and the deadlines would be only labels (C1B-2)."""
        c = self.conn
        if c is not None:
            if c.closed:
                return
            c.close_reason = reason
        if self.transport is not None:
            self.transport.abort()


class Gateway:
    """The parts of the gateway the protocol needs: table, broker, DB, buckets, identification, uplink,
    device ends. app.py builds it and adds the periodic tasks."""

    def __init__(self, loop, settings: Settings, db, broker, mem_ok, tls_holder=None):
        self.loop, self.s, self.db, self.broker = loop, settings, db, broker
        self.table = Table(settings, mem_ok)
        self.table.on_supersede = self._on_supersede
        self.conns: dict[int, Protocol] = {}
        self.admission = asyncio.Lock()
        self.global_bucket = TokenBucket(settings.uplink_global_bytes_per_s, settings.uplink_global_bytes_per_s * 8)
        self.user_buckets: dict[int, TokenBucket] = {}
        self.stats = self.table.stats
        self.tls = tls_holder
        self.servers: list[asyncio.base_events.Server] = []
        self.bind_host = "0.0.0.0"
        self.stopping = False
        self._refusal_log: dict[str, float] = {}
        self.ending_devices: list[Device] = []
        # C3B-4: Disconnected writes that failed at a device's end (DB down) are retried on the cycle, bounded
        self.pending_disconnects: dict[str, float] = {}      # uid -> give-up deadline (monotonic)
        self._pd_retry_at = 0.0

    # -- helpers ---------------------------------------------------------------------------------
    def spawn(self, coro) -> asyncio.Task:
        t = self.loop.create_task(coro)
        t.add_done_callback(_log_task_error)
        return t

    async def db_call(self, fn, *args, timeout: float = 5.0):
        return await asyncio.wait_for(self.loop.run_in_executor(None, fn, *args), timeout)

    def user_bucket(self, user_id: int) -> TokenBucket:
        b = self.user_buckets.get(user_id)
        if b is None:
            b = self.user_buckets[user_id] = TokenBucket(self.s.uplink_bytes_per_s * 2, self.s.uplink_bytes_per_s * 16)
        return b

    def log_refusal(self, line: str) -> None:
        """One line per distinct refusal REASON per minute (a flood must not flood the log; the key carries no
        uid/address so the table stays bounded)."""
        now = time.monotonic()
        key = line.rsplit(":", 1)[-1].strip()[:60]
        if now - self._refusal_log.get(key, 0.0) >= 60:
            self._refusal_log[key] = now
            log.warning(line)
        self.stats["refusals"] += 1

    def log_limited(self, key: str, line: str, level: int = logging.INFO) -> None:
        """One line per fixed KEY per minute for per-message conditions a peer controls (malformed, oversize,
        carry-over): the counters carry the rate, the log stays bounded (SEC-2)."""
        now = time.monotonic()
        if now - self._refusal_log.get(key, 0.0) >= 60:
            self._refusal_log[key] = now
            log.log(level, "%s (one line per minute; see the counters)", line)

    # -- listeners -------------------------------------------------------------------------------
    async def start_listeners(self) -> None:
        if self.s.tcp_enabled:
            srv = await self.loop.create_server(lambda: Protocol(self, self.s.tcp_port), self.bind_host, self.s.tcp_port,
                                                reuse_address=True, backlog=64)
            self.servers.append(srv)
            log.info("listening 8088 (allowlist: %d uids)", len(self.s.allowlist_8088))
        else:
            log.info("8088 not bound (allowlist empty)")
        # raw TCP; the handshake is started by the protocol AFTER the pending-pool/reserve admission (M2.1)
        srv = await self.loop.create_server(lambda: Protocol(self, self.s.tls_port), self.bind_host, self.s.tls_port,
                                            reuse_address=True, backlog=64)
        self._tls_server = srv
        self.servers.append(srv)
        log.info("listening %d (mTLS)", self.s.tls_port)

    async def restart_tls_listener(self) -> None:
        """The TLS context is taken per connection from `self.tls.ctx` (start_tls), so a rebuilt context is
        used by every NEW connection without touching the listener (M14 cert rotation)."""
        log.info("8089 uses the rebuilt TLS context for new connections")

    def stop_accepting(self) -> None:
        for srv in self.servers:
            srv.close()

    # -- identification (M2.5, M4, M5) ---------------------------------------------------------
    async def identify(self, proto: Protocol, c: Conn, ev: cot.Event) -> None:
        uid, callsign = ev.uid, ev.callsign
        if c.closed:
            return
        if not name_ok(uid):
            self.log_refusal(f"refusing device {uid!r} from {c.addr}: unusable uid")
            proto.close("unusable uid"); return
        if c.port == self.s.tcp_port and uid not in self.s.allowlist_8088:
            self.log_refusal(f"allowlist refused {uid} from {c.addr}: not on the allowlist")
            proto.close("not on the allowlist"); return
        adopt = False
        async with self.admission:
            if c.closed:
                return
            try:
                row = await self.db_call(self.db.eud, uid)
                if c.port == self.s.tls_port:
                    if row is not None and row["user_id"] is not None and row["user_id"] != c.user_id:
                        self.log_refusal(f"refusing device {uid} from {c.addr}: owned by user {row['user_id']}")
                        proto.close("owned by another user"); return
                    if row is None:
                        adopt = True
                    elif row["user_id"] is None:
                        if await self.db_call(self.db.eud_has_history, uid):
                            self.log_refusal(f"refusing device {uid} from {c.addr}: unowned device with history")
                            proto.close("unowned device with history"); return
                        adopt = True
                        log.info("adopted %s for user %s", uid, c.username)
                else:
                    if row is not None and row["user_id"] is not None:
                        self.log_refusal(f"refusing device {uid} from {c.addr}: an 8089 user's device (8089 wins)")
                        proto.close("8089 wins"); return
                cs_usable = bool(callsign and name_ok(callsign) and await self.db_call(self.db.callsign_free, callsign, uid))
            except asyncio.TimeoutError:
                self.log_refusal(f"refusing device {uid} from {c.addr}: db timeout")
                proto.close("db timeout"); return
            except Exception as e:
                log.warning("db error identifying %s: %s", uid, e)
                proto.close("db error"); return
            if c.closed:
                return                       # died while we awaited the DB: never becomes a device (C1A-1)
            try:
                dev, new = self.table.identify(c, uid, callsign if cs_usable else None, cs_usable)
            except Refused as r:
                self.log_refusal(f"refusing device {uid} from {c.addr}: {r.reason}")
                proto.close(r.reason); return
        dev.last_sa_start = _parse_start(ev.start) or dev.last_sa_start
        dev.last_type = ev.type
        if new:
            log.info("identified %s user=%s port=%d from %s", uid, c.username, c.port, c.addr)
            dev.cache = SessionCache(500, self.s.cache_mb * 1024 * 1024, uid)
            dev.cache.hold = True
            self.broker.register(dev.cache)
            dev.writer_wakeup = lambda d=dev: self._wake_writer(d)
            dev.writer_task = self.spawn(self._writer(dev))
            dev.channel = self.broker.device_channel("%s|%s" % dev.key, uid, dev.callsign if cs_usable else None,
                                                     lambda body, d=dev: self._on_delivery(d, body))
            await self._write_row(dev, ev, adopt)
            await self.reconcile(dev, first=True)
            await self._web_map(dev)
        else:
            log.info("superseded %s: new connection from %s", uid, c.addr)
            dev.writer_wakeup()
            await self.reconcile(dev, first=False)
        # the identifying SA is also a report: publish it, then what arrived during the identification
        if dev.ended:
            # the socket died (or the row was found owned elsewhere) during the awaits above: the SA and what
            # followed it are dropped — counted, never silent (C3A-2)
            n = 1 + len(proto.take_pre_ident())
            self.stats["pre_ident_dropped"] += n
            self.log_limited("pre-ident-dropped", f"{n} message(s) of {uid} dropped: ended during identification")
            return
        self.uplink(c, ev)
        for pending in proto.take_pre_ident():
            self.uplink(c, pending)
        # a socket that died during the awaits above was already ended by its own connection_lost (Table.identify
        # refuses a closed connection, so it never became a device after its close): nothing more to do (C2B-3)

    async def _write_row(self, dev: Device, ev: cot.Event, adopt: bool) -> None:
        """M5 store-before-route: the row before the first publish; minimal row as the fallback;
        retried later by the reconcile cycle while the cache holds. Serialised with the device's end (C3A-1)."""
        async with dev.db_lock:
            if dev.ended:
                return
            res = None
            try:
                res = await self.db_call(self.db.write_eud, dev.uid, dev.user_id, ev.callsign, ev.device, ev.os,
                                         ev.platform, ev.version, ev.phone, ev.group_name, ev.group_role,
                                         _parse_start(ev.start), adopt)
                dev.row_ok = res != "owned-elsewhere"
            except Exception as e:
                log.warning("row write for %s failed (%s): minimal row", dev.uid, e)
                try:
                    res = await self.db_call(self.db.minimal_eud, dev.uid, dev.user_id, ev.callsign, adopt)
                    dev.row_ok = res != "owned-elsewhere"
                except Exception as e2:
                    log.warning("minimal row for %s failed (%s): retry in 30 s, CoT cached", dev.uid, e2)
                    dev.row_ok = False
                    dev.row_retry_at = time.monotonic() + 30
            if res == "owned-elsewhere":
                # another user took the row between our ownership check and our write (SEC-1): first owner wins,
                # this device is ended; its cached CoT is dropped (cot_dropped_no_row) rather than recorded under it
                self.log_refusal(f"refusing device {dev.uid} from {dev.current.addr if dev.current else '?'}: "
                                 "owned by another user")
                dev.ended = True        # identify's reconcile and tail see it at once; end_device follows
                for c in dev.conns:
                    p = self.conns.get(c.cid)
                    if p is not None:
                        p.close("owned by another user")
                return
            if dev.row_ok and dev.cache is not None:
                dev.cache.hold = False
                self.broker.flush_all()

    async def _web_map(self, dev: Device) -> None:
        try:
            j = await self.db_call(self.db.eud_json, dev.uid)
            if j is not None:
                self.broker.publish_aux("flask-socketio", cot.socketio_eud_message(j))
        except Exception as e:
            log.debug("web map publish for %s skipped: %s", dev.uid, e)

    # -- uplink (M5/M6) ----------------------------------------------------------------------------
    def uplink(self, c: Conn, ev: cot.Event) -> None:
        dev = c.device
        if dev is None or dev.ended or dev.cache is None:
            return
        if ev.identifies:
            dev.last_sa_start = _parse_start(ev.start) or dev.last_sa_start
            dev.last_type = ev.type
        self.broker.publish_aux("firehose", cot.firehose_body(dev.uid, ev.raw))
        self.broker.publish_cot(dev.cache, dev.uid, ev.type, cot.uplink_body(dev.uid, ev.raw, dev.user_id))
        self.stats["uplink"] += 1

    # -- downlink (M7) ---------------------------------------------------------------------------
    def _on_delivery(self, dev: Device, body: bytes) -> bool:
        try:
            payload = cot.downlink_payload(body)
        except cot.Malformed:
            self.stats["downlink_malformed"] += 1
            return True                         # ack: a malformed body is dropped, not redelivered for ever
        return dev.enqueue(payload, None, None)

    def _wake_writer(self, dev: Device) -> None:
        ev = getattr(dev, "_wake", None)
        if ev is not None:
            ev.set()

    async def _writer(self, dev: Device) -> None:
        dev._wake = asyncio.Event()
        while not dev.ended:
            cur = dev.current
            if cur is None or cur.closed:
                dev._wake.clear()
                await dev._wake.wait()
                continue
            proto = self.conns.get(cur.cid)
            if proto is None:
                dev._wake.clear()
                await dev._wake.wait()
                continue
            if not proto.can_write.is_set():
                # back-pressure on the CURRENT socket: wait for it to drain OR for the device to change its
                # current socket (supersede / promotion / close), whichever first (C1A-2 / C1B-1)
                dev._wake.clear()
                w1 = asyncio.ensure_future(proto.can_write.wait())
                w2 = asyncio.ensure_future(dev._wake.wait())
                await asyncio.wait({w1, w2}, return_when=asyncio.FIRST_COMPLETED)
                for w in (w1, w2):
                    if not w.done():
                        w.cancel()
                continue                        # re-evaluate dev.current
            p = dev.pop_send()
            if p is None:
                dev._wake.clear()
                await dev._wake.wait()
                continue
            proto._write(p)
            self.stats["downlink"] += 1

    # -- supersede / ends (M3, M8) ----------------------------------------------------------------
    def _on_supersede(self, dev: Device, old: Conn, new: Conn) -> None:
        dev.writer_wakeup()                     # the writer must leave the old socket's back-pressure wait

    def on_connection_closed(self, c: Conn, reason: str) -> None:
        dev = self.table.connection_closed(c)
        if c.device is not None:
            log.info("connection of %s from %s closed (%s)", c.device.uid, c.addr, reason)
        if dev is not None and not self.stopping:   # at stop the stop sequence owns the goodbyes (C2A-4)
            self.spawn(self.end_device(dev, reason))

    async def end_device(self, dev: Device, reason: str) -> None:
        log.info("ended %s (%s)", dev.uid, reason)
        dev.ended = True
        self._wake_writer(dev)
        if dev.channel is not None:
            dev.channel.unbind_placed_and_close()
            self.broker.drop_device("%s|%s" % dev.key)
        async with dev.db_lock:     # after any in-flight identify / reconcile write of this device (C3A-1)
            if not dev.row_ok:
                # one last try for the row; without it cot_parser's FK would drop everything (C1A-16 / C1B-7)
                try:
                    await self.db_call(self.db.minimal_eud, dev.uid, dev.user_id, dev.callsign, False)
                    dev.row_ok = True
                except Exception as e:
                    log.warning("row for %s still missing at its end (%s): %d cached CoT dropped", dev.uid, e,
                                len(dev.cache) if dev.cache is not None else 0)
            try:
                await self.db_call(self.db.set_disconnected, [dev.uid])
                log.info("presence %s Disconnected", dev.uid)
            except Exception as e:
                # retried on the cycle for up to 10 min; a live device of the same uid cancels the retry (C3B-4)
                log.warning("presence write for %s failed: %s (retried on the cycle)", dev.uid, e)
                self.pending_disconnects[dev.uid] = time.monotonic() + 600
        if dev.cache is not None:
            if dev.row_ok:
                dev.cache.hold = False
                self.broker.publish_cot(dev.cache, dev.uid, cot.PRESENCE_TYPE,
                                        cot.uplink_body(dev.uid, cot.presence_offline(dev.uid, dev.last_type), dev.user_id))
            else:
                self.stats["cot_dropped_no_row"] += len(dev.cache)
                dev.cache.q.clear(); dev.cache.bytes = 0
            dev.cache.ending = True
            if not dev.cache.q and dev.cache.inflight == 0:
                self.broker.unregister(dev.cache)

    # -- the 30 s cycle (M8 re-assert, M9 reconcile, M5 retry) -----------------------------------
    async def reconcile(self, dev: Device, first: bool) -> None:
        if dev.ended:
            return
        async with dev.db_lock:     # never interleaved with the end's Disconnected write (C3A-1)
            try:
                if not dev.row_ok and time.monotonic() >= dev.row_retry_at:
                    await self.db_call(self.db.minimal_eud, dev.uid, dev.user_id, dev.callsign, False)
                    dev.row_ok = True
                    if dev.cache is not None:
                        dev.cache.hold = False
                        self.broker.flush_all()
                needed = await self.db_call(self.db.needed_bindings, dev.uid, dev.user_id,
                                            dev.callsign if dev.callsign_usable else None)
                cand = await self.db_call(self.db.candidate_bindings, dev.uid) if first else None
                if dev.ended:
                    return              # ended while we awaited the DB: no bindings, no Connected re-assert (C3A-1)
                if dev.channel is not None:
                    dev.channel.set_needed(needed, cand)
                if dev.row_ok and await self.db_call(self.db.set_connected, dev.uid, dev.last_sa_start):
                    self.stats["presence_reasserted"] += 1
            except asyncio.TimeoutError:
                log.warning("reconcile %s: db timeout", dev.uid)
            except Exception as e:
                log.warning("reconcile %s failed: %s", dev.uid, e)
            finally:
                dev.last_reconcile = time.monotonic()

    async def retry_disconnects(self) -> None:
        """C3B-4: the Disconnected writes that failed at a device's end, retried every 30 s for 10 min."""
        now = time.monotonic()
        live = {d.uid for d in self.table.devices.values() if not d.ended}
        for uid in list(self.pending_disconnects):
            if uid in live:
                self.pending_disconnects.pop(uid)       # it came back: its reconcile owns the row now
            elif now > self.pending_disconnects[uid]:
                self.pending_disconnects.pop(uid)
                self.stats["presence_retry_dropped"] += 1
                log.warning("presence Disconnected for %s not written within 10 min: given up", uid)
        uids = list(self.pending_disconnects)
        if not uids:
            return
        try:
            await self.db_call(self.db.set_disconnected, uids)
        except Exception as e:
            log.warning("presence retry for %d device(s) failed: %s", len(uids), e)
            return
        for uid in uids:
            self.pending_disconnects.pop(uid, None)
            log.info("presence %s Disconnected (retried)", uid)

    def tick(self, now: float) -> None:
        """Every second: pending deadlines, superseded deadlines, reconcile due."""
        for proto in list(self.conns.values()):
            c = proto.conn
            if c is None or c.closed:
                continue
            if c.device is None:
                why = self.table.pending_deadline_due(c, now)
                if why:
                    self.log_refusal(f"refusing pending from {c.addr}: {why}")
                    proto.close(why)
            elif self.table.superseded_due(c, now):
                proto.close("superseded: deadline")
        # a draining connection whose protocol is gone (closed before it was recorded) must not linger
        for dev in list(self.table.devices.values()):
            for c in list(dev.draining):
                if c.closed or c.cid not in self.conns:
                    self.on_connection_closed(c, "stale draining connection")
        for dev in list(self.table.devices.values()):
            if now - dev.last_reconcile >= self.s.reconcile_s and not dev.ended:
                dev.last_reconcile = now
                self.spawn(self.reconcile(dev, first=False))
        if self.pending_disconnects and now >= self._pd_retry_at:
            self._pd_retry_at = now + self.s.reconcile_s
            self.spawn(self.retry_disconnects())


def _log_task_error(t: asyncio.Task) -> None:
    if not t.cancelled() and t.exception() is not None:
        log.error("task failed: %r", t.exception())

"""M2 admission, M3 sessions keyed by DEVICE with supersede, M7 bounded downlink queue, M8 presence
hooks, M9 reconcile hooks. Pure state machine over an abstract connection (`Conn`), so the offline tests
drive it with loopback sockets or fakes; the socket I/O lives in server.py.

Vocabulary (design §1): a DEVICE (key = (user_id, uid) on 8089, (address, uid) on 8088) owns one AMQP
consumer, one cache, its placed bindings and a list of CONNECTIONS: the current socket plus at most
`max_conns_per_device - 1` superseded ones still being read (decision 4).
"""
from __future__ import annotations

import collections
import dataclasses
import logging
import time
from typing import Callable

from .bucket import TokenBucket
from .config import Settings

log = logging.getLogger("gateway.session")


class Refused(Exception):
    def __init__(self, reason: str):
        super().__init__(reason)
        self.reason = reason


@dataclasses.dataclass
class Conn:
    """One accepted socket. Owned by server.py; the session layer only reads/sets these fields and
    calls `close()` / `write()` through the callbacks server.py installed."""
    cid: int
    port: int
    addr: str
    user_id: int | None = None
    username: str | None = None
    opened: float = dataclasses.field(default_factory=time.monotonic)
    last_rx: float = dataclasses.field(default_factory=time.monotonic)
    last_msg: float = dataclasses.field(default_factory=time.monotonic)   # last COMPLETE message
    device: "Device | None" = None
    superseded_at: float | None = None
    deadline: float | None = None          # absolute monotonic deadline for a superseded conn
    closed: bool = False
    close_reason: str | None = None
    write: Callable[[bytes], None] = lambda b: None
    close: Callable[[str], None] = lambda r: None
    pause: Callable[[float], None] = lambda s: None
    uplink = None                          # TokenBucket (bytes), set at accept
    uplink_msgs = None                     # TokenBucket (messages), set at accept

    @property
    def identified(self) -> bool:
        return self.device is not None

    @property
    def is_current(self) -> bool:
        return self.device is not None and self.device.current is self


class Device:
    def __init__(self, key: tuple, uid: str, port: int, user_id: int | None, username: str | None,
                 callsign: str | None, callsign_usable: bool, settings: Settings):
        self.key, self.uid, self.port = key, uid, port
        self.user_id, self.username = user_id, username
        self.callsign = callsign
        self.callsign_usable = callsign_usable
        self.s = settings
        self.current: Conn | None = None
        self.draining: list[Conn] = []
        self.sendq: collections.deque[bytes] = collections.deque()
        self.sendq_bytes = 0
        self.sendq_dropped = 0
        self.identified_at = time.monotonic()
        self.last_sa_start = None         # the phone's SA `start` (datetime), for presence
        self.last_type: str = "a-f-G-U-C"
        self.cache = None                 # amqp.SessionCache, set by the server
        self.channel = None               # amqp.DeviceChannel
        self.row_ok = False               # store-before-route: the euds row exists
        # identify() writes the row and runs the first reconcile itself: the 30 s cycle and the row retry start
        # after it, never concurrently with it (a cycle at once raced the row insert, UniqueViolation on 04)
        self.row_retry_at = time.monotonic() + settings.reconcile_s
        self.last_reconcile = time.monotonic()
        self.ended = False
        self.writer_wakeup: Callable[[], None] = lambda: None

    @property
    def conns(self) -> list[Conn]:
        return ([self.current] if self.current else []) + self.draining

    # -- downlink queue (M7) ---------------------------------------------------------------------
    def enqueue(self, payload: bytes, uid_hint: str | None, etype_hint: str | None) -> bool:
        if self.ended:
            return False
        self.sendq.append(payload)
        self.sendq_bytes += len(payload)
        limit_b = self.s.sendq_mb * 1024 * 1024
        if len(self.sendq) > 200 or self.sendq_bytes > limit_b:
            self._bound_sendq()
        self.writer_wakeup()
        return True

    def _bound_sendq(self) -> None:
        # coalesce a-* per uid (cheap scan of the uid attr), then drop the oldest
        seen: set[bytes] = set()
        kept: collections.deque[bytes] = collections.deque()
        for p in reversed(self.sendq):
            if b'type="a-' in p[:400]:
                i = p.find(b'uid="')
                if i >= 0:
                    j = p.find(b'"', i + 5)
                    u = p[i + 5:j]
                    if u in seen:
                        self.sendq_dropped += 1
                        continue
                    seen.add(u)
            kept.appendleft(p)
        self.sendq = kept
        self.sendq_bytes = sum(len(p) for p in kept)
        limit_b = self.s.sendq_mb * 1024 * 1024
        while self.sendq and (len(self.sendq) > 200 or self.sendq_bytes > limit_b):
            p = self.sendq.popleft(); self.sendq_bytes -= len(p); self.sendq_dropped += 1

    def pop_send(self) -> bytes | None:
        if not self.sendq:
            return None
        p = self.sendq.popleft(); self.sendq_bytes -= len(p)
        return p


class Table:
    """The session table + admission (M2) + supersede (M3). All methods run on the loop thread."""

    def __init__(self, settings: Settings, mem_reserve_ok: Callable[[], bool]):
        self.s = settings
        self.mem_ok = mem_reserve_ok
        self.devices: dict[tuple, Device] = {}
        self.pending: dict[int, Conn] = {}           # cid -> not-yet-identified connections
        self.pending_by_user: dict[int, int] = collections.Counter()
        self.new_dev_buckets: dict[int, TokenBucket] = {}
        self.seen_uids_by_user: dict[int, set[str]] = collections.defaultdict(set)
        self.stats = collections.Counter()
        self.on_supersede: Callable[[Device, Conn, Conn], None] = lambda d, old, new: None

    # -- accept (M2.1, M2.4) ---------------------------------------------------------------------
    def accept(self, c: Conn) -> None:
        """Called right after accept (before TLS). Enforces the pending pool: evict the OLDEST pending
        connection on overflow (never the newcomer), and the memory reserve."""
        if not self.mem_ok():
            self.stats["refused_memory"] += 1
            raise Refused("memory reserve")
        if len(self.pending) >= self.s.max_pending:
            oldest = min(self.pending.values(), key=lambda x: x.opened)
            self.stats["evicted_pending"] += 1
            oldest.close("pending pool full: evicted (oldest)")
            self._forget_pending(oldest)
        self.pending[c.cid] = c

    def after_handshake(self, c: Conn) -> None:
        """8089: the cert's user is known. Per-user cap on unidentified connections (M2.4)."""
        if c.user_id is None or c.cid not in self.pending:
            return                             # closed during the cert lookup: nothing to count (C1A-11)
        n = self.pending_by_user[c.user_id]
        if n >= self.s.max_pending_per_user:
            # close the oldest unidentified connection of this user
            olds = [p for p in self.pending.values() if p.user_id == c.user_id and p.cid != c.cid]
            if olds:
                o = min(olds, key=lambda x: x.opened)
                self.stats["evicted_pending_user"] += 1
                o.close("too many unidentified connections for this user")
                self._forget_pending(o)
        self.pending_by_user[c.user_id] += 1

    def _forget_pending(self, c: Conn) -> None:
        if self.pending.pop(c.cid, None) is not None and c.user_id is not None:
            self.pending_by_user[c.user_id] = max(0, self.pending_by_user[c.user_id] - 1)

    def pending_deadline_due(self, c: Conn, now: float) -> str | None:
        """M2.4: rolling IDENT_MAX_S between complete messages; absolute IDENT_HARD_S from open."""
        if now - c.opened > self.s.ident_hard_s:
            return "not identified within the hard limit"
        if now - c.last_msg > self.s.ident_max_s:
            return "sent no complete message within the deadline"
        return None

    # -- identification (M2.5, M3) ---------------------------------------------------------------
    def identify(self, c: Conn, uid: str, callsign: str | None, callsign_usable: bool) -> tuple[Device, bool]:
        """Admit the connection as (a connection of) a device. Returns (device, is_new_device).
        Raises Refused. The caller holds the admission lock and has done the DB-side ownership checks."""
        if c.closed:
            raise Refused("connection closed")
        key = (c.user_id, uid) if c.port == self.s.tls_port else (c.addr, uid)
        dev = self.devices.get(key)
        if dev is None:
            if len(self.devices) >= self.s.max_devices:
                self.stats["refused_devices"] += 1
                raise Refused("device cap")
            if c.user_id is not None:
                mine = sum(1 for d in self.devices.values() if d.user_id == c.user_id)
                if mine >= self.s.max_devices_per_user:
                    self.stats["refused_devices_user"] += 1
                    raise Refused("per-user device cap")
                if uid not in self.seen_uids_by_user[c.user_id]:
                    b = self.new_dev_buckets.get(c.user_id)
                    if b is None:
                        b = self.new_dev_buckets[c.user_id] = TokenBucket(
                            rate=self.s.new_devices_per_h / 3600.0, burst=self.s.new_devices_burst)
                    if not b.take(1):
                        self.stats["refused_new_device_rate"] += 1
                        raise Refused("new-device rate")
                    self.seen_uids_by_user[c.user_id].add(uid)
            if not self.mem_ok():
                self.stats["refused_memory"] += 1
                raise Refused("memory reserve")
            dev = Device(key, uid, c.port, c.user_id, c.username, callsign, callsign_usable, self.s)
            self.devices[key] = dev
            dev.current = c
            c.device = dev
            self._forget_pending(c)
            self.stats["devices_identified"] += 1
            return dev, True
        # an existing device: this connection supersedes the current one (M3)
        self._forget_pending(c)
        old = dev.current
        c.device = dev
        if old is not None and old is not c:
            now = time.monotonic()
            old.superseded_at = now
            outage = now - old.last_rx
            old.deadline = now + min(outage + self.s.supersede_quiet_s, self.s.supersede_max_s)
            dev.draining.append(old)
            self.stats["superseded"] += 1
            self.on_supersede(dev, old, c)
            # cap: current + (max_conns - 1) draining; close the oldest draining beyond it
            while len(dev.draining) > self.s.max_conns_per_device - 1:
                victim = min(dev.draining, key=lambda x: x.opened)
                dev.draining.remove(victim)
                self.stats["closed_excess_conns"] += 1
                victim.close("too many connections for this device")
        dev.current = c
        return dev, False

    def note_rx(self, c: Conn, now: float) -> None:
        """A byte arrived on a superseded connection while a newer one lives: extend by QUIET_S."""
        c.last_rx = now
        if c.superseded_at is not None and c.device is not None and c.device.current is not c:
            c.deadline = max(c.deadline or 0.0, now + self.s.supersede_quiet_s)

    def superseded_due(self, c: Conn, now: float) -> bool:
        if c.superseded_at is None or c.deadline is None:
            return False
        if c.device is not None and c.device.current is None:
            # the newer one ended first: at most MAX_S after the supersede
            return now >= min(c.deadline, c.superseded_at + self.s.supersede_max_s)
        return now >= c.deadline

    # -- ends ------------------------------------------------------------------------------------
    def connection_closed(self, c: Conn) -> Device | None:
        """Remove a connection. Returns the device if THIS was its last connection (the device ends),
        else None. B2-10: when the current ends while draining ones live, promote the newest."""
        self._forget_pending(c)
        dev = c.device
        if dev is None:
            return None
        if dev.current is not c and c not in dev.draining:
            return None                        # already removed (a second connection_closed for the same conn, C2A-3)
        if dev.current is c:
            dev.current = None
            live = [x for x in dev.draining if not x.closed]
            if live:
                newest = max(live, key=lambda x: x.opened)
                dev.draining.remove(newest)
                newest.superseded_at = None
                newest.deadline = None
                dev.current = newest
                self.stats["promoted"] += 1
            dev.writer_wakeup()
        elif c in dev.draining:
            dev.draining.remove(c)
        if dev.current is None and not dev.draining:
            dev.ended = True
            self.devices.pop(dev.key, None)
            return dev
        return None

    # -- snapshot --------------------------------------------------------------------------------
    def snapshot(self, now: float) -> dict:
        devs = []
        for d in self.devices.values():
            devs.append({
                "key": [str(k) for k in d.key], "uid": d.uid, "user": d.username, "port": d.port,
                "connections": [{
                    "addr": c.addr, "age_s": round(now - c.opened, 1),
                    "superseded_age_s": (None if c.superseded_at is None else round(now - c.superseded_at, 1)),
                    "last_rx_age_s": round(now - c.last_rx, 1), "current": c is d.current,
                } for c in d.conns],
                "cache": (len(d.cache) if d.cache is not None else 0),
                "sendq": len(d.sendq), "sendq_dropped": d.sendq_dropped,
                "bindings": (sorted("%s:%s:%s" % b for b in d.channel.placed) if d.channel else []),
                "row_ok": d.row_ok,
            })
        return {"devices": devs, "pending": len(self.pending), "counters": dict(self.stats)}

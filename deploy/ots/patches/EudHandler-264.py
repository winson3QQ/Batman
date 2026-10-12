# SPDX-License-Identifier: GPL-3.0-or-later
# OpenTAKServer 1.7.13 opentakserver/eud_handler/EudHandler.py, (c) the OpenTAKServer authors.
# Modified by the Batman project for winson3QQ/Batman#264 on 2026-10-07 (every change is marked
# BATMAN-264); see deploy/ots/patches/README.md. Distributed under the GNU GPL v3 or later.
import base64
import datetime
import json
import logging
import os
import platform
import random
import re
import socketserver
import sys
import traceback
import uuid
import functools  # BATMAN-264
import time  # BATMAN-264-R4
import gc  # BATMAN-264-R7
import socket as socket_mod  # BATMAN-264-R6 (upstream imports the socket CLASS as 'socket')
import fcntl  # BATMAN-264-R12
import hashlib  # BATMAN-264-R17
import signal  # BATMAN-264-R17
import struct  # BATMAN-264-R12
import threading  # BATMAN-264
from logging.handlers import TimedRotatingFileHandler
from socket import socket, SHUT_RDWR
from threading import Thread
from xml.etree.ElementTree import Element, SubElement, tostring, fromstring, ParseError

import bleach
import colorlog
import flask_wtf
import pika
import sqlalchemy
import yaml
from bs4 import BeautifulSoup
from flask import Flask
from flask_ldap3_login import AuthenticationResponseStatus
from flask_security import SQLAlchemyUserDatastore, Security, verify_password
from flask_security.models import fsqla
from pika.channel import Channel
from sqlalchemy import insert, update, select

from opentakserver.EmailValidator import EmailValidator
from opentakserver.PasswordValidator import PasswordValidator
from opentakserver.defaultconfig import DefaultConfig
from opentakserver.extensions import logger as ots_logger, db, ldap_manager
from opentakserver.functions import iso8601_string_from_datetime, datetime_from_iso8601_string

# These unused imports are required by SQLAlchemy, don't remove them
from opentakserver.models.Alert import Alert
from opentakserver.models.CasEvac import CasEvac
from opentakserver.models.Certificate import Certificate
from opentakserver.models.Chatrooms import Chatroom
from opentakserver.models.ChatroomsUids import ChatroomsUids
from opentakserver.models.CoT import CoT
from opentakserver.models.DataPackage import DataPackage
from opentakserver.models.DeviceProfiles import DeviceProfiles
from opentakserver.models.EUD import EUD
from opentakserver.models.EUDStats import EUDStats
from opentakserver.models.Group import Group
from opentakserver.models.GroupMission import GroupMission
from opentakserver.models.GroupUser import GroupUser
from opentakserver.models.Marker import Marker
from opentakserver.models.Mission import Mission
from opentakserver.models.MissionChange import MissionChange
from opentakserver.models.MissionContentMission import MissionContentMission
from opentakserver.models.MissionInvitation import MissionInvitation
from opentakserver.models.MissionLogEntry import MissionLogEntry
from opentakserver.models.MissionUID import MissionUID
from opentakserver.models.Point import Point
from opentakserver.models.RBLine import RBLine
from opentakserver.models.Team import Team
from opentakserver.models.VideoRecording import VideoRecording
from opentakserver.models.VideoStream import VideoStream
from opentakserver.models.WebAuthn import WebAuthn
from opentakserver.models.ZMIST import ZMIST


MAX_PENDING = 1 << 20  # BATMAN-264-PA: bytes held while waiting for a closing tag (upstream: unbounded)
CACHE_MAX = 2000         # BATMAN-264-R9: cot_parser bodies held per session while the broker is away/blocked
CACHE_MAX_BYTES = 2 << 20
BATMAN_264 = "R1 R3 R4 R4b R5 R6 R7 R9 R10 R12 R13 R14 R16 R17"  # BATMAN-264: which #264 items this overlay carries (payload-conform greps it)
# BATMAN-264-R6: client-socket keepalive (seconds / count / ms): a peer that vanished is gone in about 2 minutes
KEEPALIVE_IDLE = 45
KEEPALIVE_INTVL = 15
KEEPALIVE_CNT = 4
KEEPALIVE_USER_TIMEOUT_MS = 120000
DRAIN_MAX_S = 60
# BATMAN-264-R12 (review r2 B2-6): admission. A client that sends no complete message within IDENT_MAX_S is
# closed (ATAK/iTAK send their SA as soon as they connect); at most PER_IP_MAX sessions per client address (the
# mesh routes phones with their own addresses, no NAT: fw4 masquerades on wan only, checked on the nodes).
IDENT_MAX_S = int(os.environ.get("BATMAN_264_IDENT_MAX_S", "60"))
PER_IP_MAX = int(os.environ.get("BATMAN_264_PER_IP_MAX", "8"))
# BATMAN-264-R12 (review r3, capacity): admissions are serialized through a lock in the container's /tmp, held from
# the memory check until the session's first message has been handled (or ADMIT_HOLD_S), so a crowd reconnecting at
# once (power back) is checked against memory one after the other instead of all against the same empty figure
# (measured on node 04: 16 sessions at once all passed a 110 MiB check, then used 474 MiB of 512).
ADMIT_LOCK = "/tmp/batman-264-admit.lock"
ADMIT_WAIT_S = 30
ADMIT_HOLD_S = 20  # R16: a fallback only; the lock is normally released once the session's subscription is placed
# BATMAN-264-R17 (review r6 A6-2/A6-4): the newest session of each device records itself here (this container's own
# tmpfs, every process uid 1000), so the device's previous session can be ended when it comes back (_claim)
SESS_DIR = "/tmp/batman-264-sess"
# BATMAN-264 (review r6 B6-2): white-box fault injection for the validation suite exception-264 (_fi)
FI_FILE = "/tmp/batman-264-fi"
# upstream's ForkingTCPServer listens with a backlog of 5: a crowd of connects overflows it and the kernel drops
# the handshake's last ACK (the client thinks it is connected, the server never accepted it; measured: 10 at once
# from one address -> 8 accepted). somaxconn on the nodes is 4096.
socketserver.ForkingTCPServer.request_queue_size = 64
# BATMAN-264-R7: a new session is refused when the container has less than this much memory left. Measured on the
# node (2026-10-11, 512 MiB cgroup): upstream costs 39 MB per idle session (the child's Flask+Security build 28.6 MB
# plus the child's first gc pass copying 58.7 MB of the parent's heap); the kernel OOM-kills the whole container
# (PID 1 = every session) at about the 10th client. With the shared app and gc.freeze() below a session costs a
# few MB, and the reserve turns the remaining limit into a refused connection instead of a container kill.
# Review r6 (A6-1/B6): 96 MiB = one whole session (~22-25 MiB, rc wsl.12/13) checked under the lock, plus the send
# buffers a few slow phones can fill after admission (up to 4 MiB each); at the shipping 1280m the RTO case peaks
# at 836-934 MiB (rc wsl.13), so the reserve is never reached there.
SESSION_RESERVE_MB = int(os.environ.get("BATMAN_264_SESSION_RESERVE_MB", "96"))
CG_DIR = "/sys/fs/cgroup"  # this container's own cgroup (cgroup v2, namespaced)


# BATMAN-264-R10: the client's uid and callsign become queue names (declare/bind/consume) on the shared broker,
# unauthenticated on 8088. A callsign equal to a system queue would consume that queue (callsign "cot_parser"
# steals every CoT from storage, round-robin with cot_parser); "amq.*" is refused by the broker with a channel
# error; a name over 255 bytes raises inside pika. An unusable or owned CALLSIGN is not used as a queue and the device
# is still subscribed by its uid and RECORDED (the user's decision 2026-10-12, review r4); an unusable or owned UID
# gets no subscription and no row update (its CoT go to that uid's existing row, if any).
RESERVED_NAMES = frozenset({"cot_parser", "dms", "chatrooms", "missions", "groups", "firehose", "flask-socketio",
                            "meshtastic", "dmrcot"})


def _valid_name(name):
    if not isinstance(name, str) or not name or len(name.encode("utf-8", "replace")) > 255:
        return False
    if name.lower().startswith("amq.") or name in RESERVED_NAMES:  # queue names are case-sensitive (r2 B2-3)
        return False
    return all(c.isprintable() for c in name)


def _cg_mem():
    """(used, max) bytes of this container's own cgroup; (None, None) when unreadable (then no cap). "Used" is what
    the kernel charges to the limit and cannot simply drop: memory.current minus the page cache ("file" in
    memory.stat, reclaimable). That is the anonymous memory AND the kernel memory, socket buffers included
    (BATMAN-264-R16: stale sessions' unsent data, up to tcp_wmem 4 MiB each, is charged to the limit but not to
    "anon"). memory.current alone would refuse sessions after days of log writes (review B-6)."""
    try:
        with open(CG_DIR + "/memory.current") as f:
            cur = int(f.read())
        fil = 0
        with open(CG_DIR + "/memory.stat") as f:
            for line in f:
                if line.startswith("file "):
                    fil = int(line.split()[1])
                    break
        with open(CG_DIR + "/memory.max") as f:
            mx = f.read().strip()
        return cur - fil, (None if mx == "max" else int(mx))
    except (OSError, ValueError):
        return None, None


def _phone_int(phone):
    """BATMAN-264-R14 (review r5): euds.phone_number is a BigInteger. A phone such as '555-123-4567' made the row
    insert fail every time; its digits are kept (up to 18), anything else becomes None."""
    d = re.sub(r"\D", "", str(phone or ""))
    return int(d) if d and len(d) <= 18 else None


def _proc_start(pid):
    # BATMAN-264-R17: a process's start time (clock ticks since boot, /proc/<pid>/stat field 22). Together with the
    # pid it names one process: a reused pid has another start time.
    try:
        with open(f"/proc/{pid}/stat", "rb") as f:
            st = f.read()
        return int(st[st.rindex(b")") + 2:].split()[19])
    except (OSError, ValueError, IndexError):
        return None


def _oom_first():
    """BATMAN-264-R16: this session process volunteers to be the memcg OOM killer's first choice (oom_score_adj
    1000). Without it the killer picks the largest process, the listener parent, and the container ends with every
    session (reproduced on node 04, rc wsl.11). With it, the worst case is one session: its phone reconnects.
    Raising one's own score needs no privilege (probed on node 04 as uid 1000)."""
    try:
        with open("/proc/self/oom_score_adj", "w") as f:
            f.write("1000")
        return True
    except OSError as e:
        logging.getLogger().error(f"BATMAN-264-R16: oom_score_adj not set ({e}); an OOM may take the listener")
        return False


def _sessions_from(ip, port):
    """BATMAN-264-R12: established TCP connections from ip to our listening port, read from this container's own
    /proc/net/tcp (the forked sessions share the network namespace; this session's socket is counted). None when
    unreadable: then only the memory reserve applies (fail-open, logged by the caller)."""
    try:
        want = "%08X" % struct.unpack("<I", socket_mod.inet_aton(ip))[0]
        port_hex = "%04X" % port
        n = 0
        for path, rem in (("/proc/net/tcp", want), ("/proc/net/tcp6", "0000000000000000FFFF0000" + want)):
            try:
                with open(path) as f:
                    next(f)
                    for line in f:
                        p = line.split()
                        if p[3] == "01" and p[1].endswith(":" + port_hex) and p[2].split(":")[0] == rem:
                            n += 1
            except FileNotFoundError:
                pass
        return n
    except (OSError, ValueError, struct.error, StopIteration):
        return None


def _before_fork():
    # BATMAN-264-R7: the parent's heap is read-only for a session; freezing it keeps the child's garbage
    # collector from writing every gc header and so copying the pages (measured: 58.7 MB -> 2.6 MB per child).
    # Freeze ONCE and never collect the frozen heap in the parent again: a parent-side full collection after
    # a fork writes every gc header too, and with children alive that copies the parent's whole heap for the
    # parent (measured on the node: 1st session 33 MB, every further one 78 MB with collect+freeze per fork).
    if gc.get_freeze_count() == 0:
        _prewarm_parent()
        gc.collect()
        gc.freeze()


def _prewarm_parent():
    # BATMAN-264-R7: work every session would otherwise do first in its own child, done once in the parent so
    # the children share the result: SQLAlchemy's lazy mapper configuration and the first ORM statement build
    # (measured 19.6 MB in a child, the largest remaining per-session cost), the engine object (the pool is
    # replaced in each child), and the XML parser plugin. Never fatal: a failure here only costs memory.
    try:
        entry = sys.modules.get("opentakserver.eud_handler.eud_handler")
        app = getattr(entry, "app", None)
        if isinstance(app, Flask):
            from sqlalchemy.orm import configure_mappers
            from opentakserver.models.EUD import EUD as _EUD
            with app.app_context():
                db.engine
                configure_mappers()
                str(select(_EUD).filter_by(uid="warm"))
        BeautifulSoup('<event uid="warm"><detail><contact callsign="warm"/></detail></event>', "xml")
    except Exception as e:  # pragma: no cover - diagnostic only
        logging.getLogger().error(f"BATMAN-264-R7 pre-warm skipped: {e}")


if hasattr(os, "register_at_fork"):
    os.register_at_fork(before=_before_fork)


class _OpRecorder:  # BATMAN-264: records channel calls made on the handler thread, replayed on the ioloop
    def __init__(self):
        self.ops = []

    def __getattr__(self, name):
        def rec(*a, **k):
            self.ops.append((name, a, k))
        return rec


class EudHandler(socketserver.BaseRequestHandler):

    timeout = 1.0
    shutdown = False
    common_name = None
    user = None
    is_ssl = False
    logger = ots_logger
    app = None
    rabbit_connection = None
    rabbit_channel = None
    iothread = None
    is_consuming = False
    is_authenticated = False
    cached_messages = []
    eud = None
    callsign = None
    uid = None
    bound_queues = []
    phone_number = None
    group_memberships = []

    def __init__(self, request: socket, client_address, server):
        super().__init__(request, client_address, server)
        self.logger = logging.getLogger()
        self.socket: socket = request

    def handle(self):
        # BATMAN-264-PA (#264 mechanism A): upstream split each recv on </event>, and when a recv ended inside a
        # message it saved the partial (cot = c) and then wiped it (cot = ""), so every message cut by a TCP
        # segment or a coalesced write was lost (measured 20-35 %). Keep raw BYTES until a closing tag is seen
        # (a multi-byte UTF-8 character split across recvs must not raise), decode only complete messages,
        # carry the remainder, and drop only a message that really is malformed.
        buf = b""
        scan = 0
        first_by = time.monotonic() + IDENT_MAX_S  # BATMAN-264-R12: a complete message is due by then
        try:
            self._handle_loop(buf, scan, first_by)
        finally:
            # BATMAN-264 (review r3 A3-2): whatever leaves the loop, the session end runs and is waited for
            self._release_admit()
            self.close_connection()
            self._wait_end()
            self._unclaim()  # BATMAN-264-R17

    def _handle_loop(self, buf, scan, first_by):
        while not self.shutdown:
            try:
                if first_by is not None:
                    self.request.settimeout(max(0.1, first_by - time.monotonic()))
                data = self.request.recv(65536)
            except (socket_mod.timeout, TimeoutError):
                self.logger.error(f"{self.client_address[0]} sent no complete message within {IDENT_MAX_S} s "
                                  f"(not identified); closing (BATMAN-264-R12)")
                break
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
                if self._admit_pending:
                    # BATMAN-264-R12/R16: admissions are serialized from here until the subscription is placed
                    self._admit_pending = False
                    self._take_admit()
                    if not self._session_allowed():
                        self._release_admit()
                        self._refused = True
                        break
                    self._open_broker()  # BATMAN-264-R16 (r6 A6-1): allocated under the lock
                try:
                    fromstring(msg)
                    if tag == b"</event>":
                        self.handle_cot(msg)
                    else:
                        self.handle_auth(msg)
                except ParseError as e:
                    self.logger.error(f"Failed to parse: {e}")
                except Exception as e:
                    # BATMAN-264 (review r3 A3-2): upstream let any exception out of handle_cot (a CoT without a
                    # start attribute: KeyError in parse_device_info) end the child without the session end: its
                    # queues stayed bound with no consumer (measured on node 04). The message is dropped, the
                    # session goes on.
                    self.logger.error(f"{self.client_address[0]}: a message raised {type(e).__name__}: {e}; dropped")
                    self.logger.debug(traceback.format_exc())
                if not self._sub_wanted:
                    # BATMAN-264-R12/R16: this session's first work is done. A session that asked for its subscription
                    # keeps the lock until _subscribe has placed it, so the next admission's memory check sees what
                    # this one really costs (rc wsl.11: released here, 16 reconnects all passed while still growing).
                    # Review r6 A6-3/B6-3: a ping or an <auth> before the identifying CoT releases the lock at once (r5
                    # held it for ADMIT_HOLD_S: one ping every 20 s switched serialization off for everyone) and the
                    # next message is admitted again, under the lock, with its own memory check.
                    ping = tag != b"</event>" or b'type="t-x-c-t"' in chunk[:600]
                    if self._release_admit() and ping and self.uid is None:
                        self._admit_pending = True
                if first_by is not None:
                    # BATMAN-264-R12 (review r3 B3-3): one parsable message used to clear the deadline for good (an
                    # empty <event/> kept a socket for ever). Until the client identifies, every complete message
                    # only moves the deadline IDENT_MAX_S further: a relay that keeps sending is never cut, a socket
                    # that goes silent before identifying is.
                    if self.uid is not None:
                        first_by = None
                        self.request.settimeout(None)
                    else:
                        first_by = time.monotonic() + IDENT_MAX_S
            if self._refused:
                break
            if len(buf) > MAX_PENDING:
                self.logger.error(f"{len(buf)} bytes without a closing tag from {self.client_address[0]}, dropped")
                buf, scan = b"", 0

    def pong(self, event):
        if event.attrs.get("type") == "t-x-c-t":
            now = datetime.datetime.now(datetime.timezone.utc)
            stale = now + datetime.timedelta(seconds=10)

            cot = Element(
                "event",
                {
                    "how": "h-g-i-g-o",
                    "type": "t-x-c-t-r",
                    "version": "2.0",
                    "uid": "{}-pong".format(event.attrs.get("uid")),
                    "start": iso8601_string_from_datetime(now),
                    "time": iso8601_string_from_datetime(now),
                    "stale": iso8601_string_from_datetime(stale),
                },
            )
            SubElement(
                cot, "point", {"ce": "9999999", "le": "9999999", "hae": "0", "lat": "0", "lon": "0"}
            )

            try:
                self.request.send(event.encode())
                return True
            except BaseException as e:
                self.logger.error(f"Pong error: {e}")

        return False

    def setup(self):
        # BATMAN-264: per-instance state (upstream used class attributes) + ioloop liveness / drain signals
        self.cached_messages = []
        self.bound_queues = []
        self.group_memberships = []
        self._loop_dead = False
        self._closed = False
        self._pending_ops = None
        self._blocked = False        # BATMAN-264-R9: broker flow control (connection.blocked)
        self._cache_bytes = 0
        self._dropped = 0
        self._decl_channel = None    # BATMAN-264-R5: the cot_parser declare runs on its own channel
        self._decl_refused = False
        self._retry_n = 0
        self._retry_timer = None
        self._head_returned = False
        self._pub_seq = 0            # BATMAN-264-R4b: publishes on rabbit_channel since Confirm.Select (broker numbering)
        self._unacked = {}           # seq -> (body, meta) of cot_parser publishes not yet acked (insertion-ordered)
        self._returned = set()       # seqs that came back via basic.return (already re-cached; their ack is not a delivery)
        self._sub_ops = None
        self._chan_errors = []
        self._reconnect_n = 0
        self._reconnect_timer = None
        self._ioloop = None
        self._end_args = None        # BATMAN-264-R4b: (uid, body, binds) of a client that left while the broker was away
        self._subscribed = False     # BATMAN-264-R10: the per-EUD subscription is made once per session
        self._squat_logged = False
        self._sub_binds = []         # BATMAN-264-R6: the bindings this session placed (none: it removes none)
        self._sub_binds_pending = []
        self._relay = False          # an RF relay platform (Meshtastic/ICU/DMRCOT): no queues, upstream's disconnect
        self._close_lock = threading.Lock()   # r2 A2-4: close_connection's test-and-set is atomic
        self._end_done = threading.Event()    # r2 A2-4/A2-6: set only when THIS session's end is complete
        self._final_close = False
        self._end_deadline = None
        self._admit_fd = None        # R12: the admission lock, released after the first message (or ADMIT_HOLD_S)
        self._admit_mx = threading.Lock()
        self._chan_opening = False   # a channel open is in flight (the end opens one to drain)
        self._ret_n = 0              # returns of one burst keep their order at the cache head
        self.iothread = None
        self._sub_wanted = False     # R16: a subscription was requested: the admission lock is held until it is placed
        self._cs_queue = True        # R10 (r4): the callsign is used as a queue (False: subscribed by uid only)
        self._admit_pending = False  # R16 (r4): the admission lock is taken at the first complete message
        self._refused = False
        self._goodbye = None         # r4 (A3-6): the end's (uid, body) until its CloseOk: a loss in between retries it
        self._goodbye_retried = False
        self._ident_failures = 0     # R14 (r5): bounded re-identification
        self._superseded = False     # R17 (r6): this device's newer session ended this one
        self._claimed = False        # R17 (r6): this session is in the device registry
        self._row_next = 0.0         # r6 A6-6/B6-4: when to retry a minimal EUD row that could not be written (0: none due)
        self._fi_done = False        # r6 B6-2: fault injection fires once per session
        _oom_first()                 # R16: under memory pressure the kernel kills a session, never the listener
        if not self._admit():  # BATMAN-264-R7/R12: fail closed before anything is allocated or declared
            self.shutdown = True
            try:
                self.request.close()
            except OSError:
                pass
            return
        self._keepalive(self.request)  # BATMAN-264-R6: a vanished peer ends the session in about 2 min
        signal.signal(signal.SIGUSR1, self._on_supersede)  # BATMAN-264-R17: the forked child's main thread
        # the app stays here: upstream's EudHandlerSSL.setup uses self.app right after this returns (the cert user)
        self.create_app()
        # BATMAN-264-R16 (review r6 A6-1): the broker connection is made at the session's first complete message,
        # under the admission lock (_handle_loop -> _open_broker): its memory (pika, the ioloop thread) is counted by
        # the serialized check, and a socket that never sends costs no AMQP connection

    def _open_broker(self):
        if self.rabbit_connection is not None or self._closed:
            return
        # RabbitMQ
        try:
            rabbit_credentials = pika.PlainCredentials(
                self.app.config.get("OTS_RABBITMQ_USERNAME"),
                self.app.config.get("OTS_RABBITMQ_PASSWORD"),
            )
            rabbit_host = self.app.config.get("OTS_RABBITMQ_SERVER_ADDRESS")
            self.rabbit_connection = pika.SelectConnection(
                pika.ConnectionParameters(
                    host=rabbit_host,
                    credentials=rabbit_credentials,
                    # BATMAN-264-R9/R13 (review r4 A4-8/B4-5): no blocked_connection_timeout. With it, a broker memory
                    # alarm over 60 s closed the connection, R13 ended every session and the drain (no acks from a
                    # blocked broker) dropped each cache. While blocked the session caches (R9 bounds), and resumes.
                    client_properties={  # BATMAN-264: name the connection so a test can find this session's
                        "connection_name": "eud-%s-%s:%s" % (
                            getattr(self.server, "server_address", ("", 0))[1], self.client_address[0], self.client_address[1])},
                ),
                self.on_connection_open,
                on_open_error_callback=self.on_open_error,  # BATMAN-264: upstream had none -> ioloop died
                on_close_callback=self.on_close,
            )
            self.rabbit_channel: Channel | None = None
            # Start the pika ioloop in a thread or else it blocks and we can't receive any CoT messages
            self._ioloop = self.rabbit_connection.ioloop  # BATMAN-264-R4: one loop for the session, connections come and go
            self.iothread = Thread(target=self._run, name=f"IOLOOP_{self.common_name}")  # BATMAN-264
            # self.iothread.daemon = True
            self.iothread.start()
            self.is_consuming = False
        except BaseException as e:
            self.logger.error("Failed to connect to rabbitmq: {}".format(e))
            return

    def finish(self):
        print("finish")

    def close_connection(self):
        # BATMAN-264: starts the session end exactly once. handle_auth, handle(), the ioloop (a send failure in
        # on_message) and the channel-error rule can all call it, from two threads: the test-and-set is atomic
        # (review r2 A2-4). All channel work runs on the ioloop (pika is not thread-safe); the HANDLER thread
        # waits for the end in _wait_end() whoever started it, so the forked child does not os._exit() with the
        # drain, the disconnect or the unbinds still in flight (r2 A2-4: an ioloop-started end was not waited for).
        # Upstream published before checking the channel (ChannelWrongStateError, upstream #404).
        with self._close_lock:
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
        if self.cached_messages or self._dropped:  # BATMAN-264-R9: never silent
            self.logger.error(f"session end: {len(self.cached_messages)} cached and {self._dropped} dropped cot not delivered yet")
        self._end_done.clear()
        if not self._io(self._begin_end, self.uid, body):
            self._end_done.set()  # no ioloop: nothing to drain or tell the broker

        if not self.shutdown:
            self.shutdown = True

            try:
                self.request.shutdown(SHUT_RDWR)  # BATMAN-264: ENOTCONN on a socket already closed by the peer
            except OSError:
                pass
            try:
                self.request.close()
            except OSError:
                pass

    def _wait_end(self):
        if self.iothread is None or threading.current_thread() is self.iothread:
            return
        if not self._end_done.wait(2 * DRAIN_MAX_S + 10):  # r5 A5-7: room for the one retried goodbye (A3-6)
            self.logger.error(f"session end of {self.client_address[0]} did not complete within {2 * DRAIN_MAX_S + 10} s")

    # ---- BATMAN-264-R4b/R6: the session end, on the ioloop: drain (bounded), then disconnect/unbind/cleanup ----
    def _begin_end(self, uid, body):
        if uid is None and not self.cached_messages and not self._unacked:
            # review r3 A3-7: nothing to deliver and nothing cot_parser would act on (a uid-less disconnect is
            # ignored): no 60 s wait for an away broker, the child goes at once
            self._done()
            return
        self._end_args = (uid, body)
        self._end_deadline = self._ioloop.call_later(DRAIN_MAX_S, self._end_timeout)
        self._try_end()

    def _try_end(self):
        # called again by every event that can unblock the end: an ack, a reopened channel, unblocked flow
        # control, the head retry after a return. Cached bodies go first and must be ACKED (r2 A2-6/A-F18: a
        # returned body re-cached after the close was lost); then the session end proper (_end_session).
        if self._end_args is None:
            return
        ch = self.rabbit_channel
        if ch is not None and ch.is_open and not self._blocked:
            if self._retry_timer is None:
                self._flush_cache()
            if self.cached_messages or self._unacked:
                return
            self._finish_end()
            return
        c = self.rabbit_connection
        if c is not None and c.is_open:
            # flow control (unblocked calls us again), or no channel: open one for the drain (on_channel_open calls us)
            if self.rabbit_channel is None and not self._chan_opening:
                self._chan_opening = True
                try:
                    c.channel(on_open_callback=self.on_channel_open)
                except Exception as e:
                    self._chan_opening = False
                    self.logger.error(f"cannot open a channel for the session end: {e}")
            return
        if c is not None and not c.is_closed:
            return  # opening or closing: on_connection_open / on_close / on_open_error call us again
        if not self._loop_dead:
            self._schedule_reconnect()  # the broker is away: deliver and say goodbye once it is back (bounded)
            return
        self._done()

    def _finish_end(self):
        uid, body = self._end_args
        self._end_args = None
        self._goodbye = (uid, body)  # review r3 A3-6: kept until the end's CloseOk
        if self._end_deadline is not None:
            try:
                self._ioloop.remove_timeout(self._end_deadline)
            except Exception:
                pass
            self._end_deadline = None
        self._end_session(uid, body)

    def _end_timeout(self):
        self._end_deadline = None
        if self._end_args is None:
            return
        self.logger.error(f"session end: {len(self.cached_messages)} cached and {len(self._unacked)} unacked cot not "
                          f"delivered within {DRAIN_MAX_S} s")
        if self.rabbit_channel is not None and self.rabbit_channel.is_open:
            self._finish_end()  # disconnect and unbind anyway; the undelivered bodies are counted above
        else:
            self._done()

    def _done(self):
        # the end is complete (or cannot be told to the broker): release the handler, close the connection, which
        # stops the loop (on_close)
        if self._end_deadline is not None:
            try:
                self._ioloop.remove_timeout(self._end_deadline)
            except Exception:
                pass
            self._end_deadline = None
        self._end_args = None
        self._end_done.set()
        c = self.rabbit_connection
        try:
            if c is not None and c.is_open:
                c.close()
                return
        except Exception:
            pass
        try:
            self._ioloop.stop()
        except Exception:
            pass

    def _owned_by_user(self, uid, callsign):
        # BATMAN-264-R10: is this uid, and is this callsign, a name (uid OR callsign column) of an EUD row that
        # belongs to an OTS user (an 8089 device)? Both names against both columns: a queue is named by either, so a
        # callsign equal to a user's uid would consume that user's <uid> queue (review r2 B2-2, reproduced on node
        # 04). (uid_owned, callsign_owned), or (None, None) when the database did not answer (retried later).
        names = [n for n in (uid, callsign) if n]
        try:
            with self.app.app_context():
                rows = db.session.execute(
                    select(EUD.uid, EUD.callsign).filter(EUD.uid.in_(names) | EUD.callsign.in_(names))
                    .filter(EUD.user_id.isnot(None))
                ).all()
            held = {n for r in rows for n in r if n}
            return uid in held, bool(callsign) and callsign in held
        except Exception as e:
            self.logger.error(f"ownership lookup failed ({e}); not subscribing yet, retried on the next report")
            return None, None

    def _owned_by_other_user(self, uid):
        # BATMAN-264-R10 (review r3 B3-5): an EUD row with this uid that belongs to a DIFFERENT user.
        # Residual (review r4 B4-7): a phone re-issued to a new user keeps its uid; until an admin reassigns the
        # device (web UI), its 8089 session is refused its subscription (recorded, but no downlink). True / False,
        # or None when the database did not answer (the caller retries on the next identifying CoT).
        try:
            with self.app.app_context():
                row = db.session.execute(
                    select(EUD.uid).filter(EUD.uid == uid).filter(EUD.user_id.isnot(None))
                    .filter(EUD.user_id != (self.user.id if self.user else -1))
                ).first()
            return row is not None
        except Exception as e:
            self.logger.error(f"ownership lookup failed ({e}); not subscribing yet, retried on the next report")
            return None

    def _admit(self):
        # BATMAN-264-R12. Order (review r3 B3-2): the per-address count and the memory reserve first (cheap, nothing
        # allocated), so sockets that never finish TLS are bounded per address too; then the 8089 TLS handshake
        # (10 s; upstream's EudHandlerSSL.setup ran it after this setup, its own do_handshake() then is a no-op,
        # probed); then, under the admission lock, the memory reserve again (r3 capacity: serialized).
        n = _sessions_from(self.client_address[0], getattr(self.server, "server_address", ("", 0))[1])
        if n is None:
            self.logger.error("BATMAN-264-R12: /proc/net/tcp unreadable, per-address limit not applied")
        elif n > PER_IP_MAX:
            self.logger.error(f"refusing session from {self.client_address[0]}: {n} sessions from this address "
                              f"(limit {PER_IP_MAX}) (BATMAN-264-R12)")
            return False
        if not self._session_allowed():
            return False
        if self.is_ssl:
            try:
                self.request.settimeout(10)
                self.request.do_handshake()
                self.request.settimeout(None)
            except Exception as e:
                self.logger.warning(f"TLS handshake with {self.client_address[0]} failed, nothing allocated: {e}")
                return False
        # BATMAN-264-R16 (review r4 A4-3/B4-9, measured on rc wsl.12: three silent sockets held the lock 20 s each and
        # the next admission went "unserialized" after 30 s): the lock and the second memory check come at the
        # session's first complete message (_handle_loop), so a socket that sends nothing never holds the lock.
        self._admit_pending = True
        return True

    def _take_admit(self):
        # wait (bounded) for the admission lock; without it the memory check still runs (logged)
        try:
            fd = os.open(ADMIT_LOCK, os.O_RDWR | os.O_CREAT, 0o600)
        except OSError as e:
            self.logger.error(f"BATMAN-264-R12: admission lock unusable ({e}); admitting unserialized")
            return
        t0 = time.monotonic()
        while True:
            try:
                fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
                break
            except OSError:
                if time.monotonic() - t0 > ADMIT_WAIT_S:
                    os.close(fd)
                    self.logger.error(f"BATMAN-264-R12: admission lock not free within {ADMIT_WAIT_S} s; admitting unserialized")
                    return
                time.sleep(0.2)
        with self._admit_mx:
            self._admit_fd = fd
            self._admit_t0 = time.monotonic()
        self.logger.info(f"admission of {self.client_address[0]}: lock taken (BATMAN-264-R12)")
        t = threading.Timer(ADMIT_HOLD_S, self._release_admit)
        t.daemon = True
        t.start()

    def _release_admit(self):
        with self._admit_mx:
            fd, self._admit_fd = self._admit_fd, None
        if fd is not None:
            self.logger.info(f"admission of {self.client_address[0]}: lock released after "
                             f"{(time.monotonic() - getattr(self, '_admit_t0', time.monotonic())) * 1000:.0f} ms (BATMAN-264-R12)")
            try:
                os.close(fd)  # releases the flock
            except OSError:
                pass
        return fd is not None

    def _session_allowed(self):
        # BATMAN-264-R7: refuse a session while the container has less than SESSION_RESERVE_MB left, so the
        # limit shows as one refused client in the log instead of the kernel killing PID 1 and every session.
        cur, mx = _cg_mem()
        if cur is None or mx is None:
            return True
        if mx - cur < SESSION_RESERVE_MB << 20:
            self.logger.error(
                f"refusing session from {self.client_address[0]}: container memory {cur >> 20}/{mx >> 20} MiB, "
                f"less than {SESSION_RESERVE_MB} MiB free (BATMAN-264-R7)")
            return False
        return True

    def create_app(self):
        # BATMAN-264-R7: eud_handler.py builds the app once in the parent (app = create_app()) and hands it to the
        # server as app_context; the child shares it copy-on-write instead of building its own (28.6 MB measured
        # per session). The SQLAlchemy pool a child inherits is replaced without closing the parent's sockets.
        # Consequence: config.yml is read when the handler process starts, not per session.
        app = getattr(self.server, "app_context", None)
        if isinstance(app, Flask):
            with app.app_context():
                db.engine.dispose(close=False)
            self.app = app
            self.logger.debug("BATMAN-264-R7: sharing the parent's app")
            return app
        self.logger.error("BATMAN-264-R7: no parent app on the server, building one per session (upstream path)")
        return self._create_app_upstream()

    def _create_app_upstream(self):
        app = Flask(__name__)
        app.config.from_object(DefaultConfig)

        # Load config.yml if it exists
        if os.path.exists(os.path.join(app.config.get("OTS_DATA_FOLDER"), "config.yml")):
            app.config.from_file(
                os.path.join(app.config.get("OTS_DATA_FOLDER"), "config.yml"), load=yaml.safe_load
            )
        else:
            # First run, created config.yml based on default settings
            self.logger.info("Creating config.yml")
            with open(os.path.join(app.config.get("OTS_DATA_FOLDER"), "config.yml"), "w") as config:
                conf = {}
                for option in DefaultConfig.__dict__:
                    # Fix the sqlite DB path on Windows
                    if (
                        option == "SQLALCHEMY_DATABASE_URI"
                        and platform.system() == "Windows"
                        and DefaultConfig.__dict__[option].startswith("sqlite")
                    ):
                        conf[option] = (
                            DefaultConfig.__dict__[option].replace("////", "///").replace("\\", "/")
                        )
                    elif option.isupper():
                        conf[option] = DefaultConfig.__dict__[option]
                config.write(yaml.safe_dump(conf))

        db.init_app(app)

        if app.config.get("OTS_ENABLE_LDAP"):
            self.logger.info("Enabling LDAP")
            ldap_manager.init_app(app)

        # The rest is required by flask, leave it in
        try:
            fsqla.FsModels.set_db_info(db)
        except sqlalchemy.exc.InvalidRequestError:
            pass

        from opentakserver.models.role import Role
        from opentakserver.models.user import User

        flask_wtf.CSRFProtect(app)
        user_datastore = SQLAlchemyUserDatastore(db, User, Role)
        app.security = Security(
            app, user_datastore, mail_util_cls=EmailValidator, password_util_cls=PasswordValidator
        )

        self.app = app
        return app

    def on_connection_open(self, connection: pika.SelectConnection):
        # BATMAN-264-R9: broker flow control -> cache, instead of filling pika's unbounded write buffer
        connection.add_on_connection_blocked_callback(self._on_blocked)
        connection.add_on_connection_unblocked_callback(self._on_unblocked)
        # BATMAN-264-R5: the cot_parser queue declare gets its own channel: a refused declare (406 if the
        # queue's arguments ever change) closes only that channel, never the publishing one
        connection.channel(on_open_callback=self._on_decl_channel_open)
        self._chan_opening = True
        self.rabbit_connection.channel(on_open_callback=self.on_channel_open)

    def on_channel_open(self, channel: Channel):
        self.logger.debug(f"Opening RabbitMQ channel for {self.callsign or self.client_address[0]}")
        self.rabbit_channel = channel
        self._chan_opening = False
        self.rabbit_channel.add_on_close_callback(self.on_channel_close)
        self.rabbit_channel.add_on_return_callback(self._on_return)  # BATMAN-264-R5: unroutable -> cache
        self.rabbit_channel.confirm_delivery(self._on_confirm)      # BATMAN-264-R4b: at-least-once
        self._pub_seq = 0
        self._requeue_unacked()
        self._reconnect_n = 0
        self.rabbit_channel.exchange_declare(
            "flask-socketio", durable=False, exchange_type="fanout"
        )

        if self._pending_ops and not self._closed:  # BATMAN-264: a subscription requested before the channel was open
            ops, self._pending_ops = self._pending_ops, None
            self._subscribe(ops)

        self._flush_cache()  # BATMAN-264-R9: cot_parser bodies cached while the channel was closed/blocked
        if self._end_args is not None:  # BATMAN-264-R4b: the client already left: deliver, then end
            self._try_end()
            return

        # Publish the EUD info to flask-socketio for the web UI map
        if self.eud:
            message = {
                "method": "emit",
                "event": "eud",
                "data": self.eud.to_json(),
                "namespace": "/socket.io",
                "room": None,
                "skip_sid": [],
                "callback": None,
                "binary": False,
                "host_id": uuid.uuid4().hex,
            }
            self._publish_on_ioloop("flask-socketio", "", json.dumps(message))  # BATMAN-264-R4b: counted

    def _retry_goodbye(self):
        # review r3 A3-6: the channel or the connection was lost while the goodbye (disconnect, unbinds) was in
        # flight: once, put it back and run the end again (it reconnects, bounded by a new DRAIN_MAX_S deadline)
        if self._goodbye is None or self._goodbye_retried or self._final_close:
            return False
        self._goodbye_retried = True
        self._end_args, self._goodbye = self._goodbye, None
        self.logger.error(f"session end of {self.client_address[0]}: the channel or connection closed during the goodbye; "
                          f"retrying it once")
        self._end_deadline = self._ioloop.call_later(DRAIN_MAX_S, self._end_timeout)
        return True

    def on_channel_close(self, channel: Channel, error):
        if not self._final_close and self._closed and self._end_args is None and self._retry_goodbye():
            self.rabbit_channel = None
            self._chan_opening = False
            self._try_end()
            return
        if self._final_close or (self._closed and self._end_args is None):
            self._done()  # CloseOk of the end (frames before it were sent), or the end's channel died: complete
            return
        self.rabbit_channel = None
        self._chan_opening = False
        self._subscribed = False
        self._requeue_unacked()
        if not (self.rabbit_connection and self.rabbit_connection.is_open):
            return  # the connection is going too: on_close handles it
        now = time.monotonic()
        self._chan_errors = [t for t in self._chan_errors if now - t < 60] + [now]
        if len(self._chan_errors) >= 3:
            self.logger.error(f"{self.callsign}: the channel keeps failing ({error}); ending the session")
            if not self._closed:
                self.close_connection()
            self._done()  # no drain or goodbye over a channel that keeps failing
            return
        if not self._closed:
            # BATMAN-264-R13 (review r3 A3-3): upstream ended the session here too; now the cache is delivered
            # first (the end opens a channel for it), then the client session ends and the phone reconnects
            self.logger.error(f"RabbitMQ channel closed for {self.callsign}: {error}; delivering the cache, then "
                              f"ending the client session (BATMAN-264-R13)")
            self.close_connection()
        else:
            self._try_end()

    def on_close(self, connection, error):
        self.logger.info("Connection closed for {}: {}".format(self.client_address[0], error))
        if self._closed and self._end_args is None and self._retry_goodbye():
            self.rabbit_channel = None
            self._decl_channel = None
            self._chan_opening = False
            self._try_end()
            return
        if self._closed and self._end_args is None:
            self._end_done.set()
            # Stop the ioloop using add_callback_threadsafe because ioloop.stop() isn't threadsafe
            connection.ioloop.add_callback_threadsafe(self._ioloop.stop)
            return
        # BATMAN-264-R4/R13 (#264 mechanism B; review r3 A3-3, the user's decision 2026-10-12): the broker ended the
        # connection (missed heartbeats, broker restart, rabbitmqctl close_connection). Upstream let the session die
        # with everything in flight. Now: the unacked bodies go back to the cache, the ioloop reconnects (backoff
        # 1..30 s) only to deliver the cache, then the CLIENT session ends; the phone reconnects and its new session
        # is subscribed from the database (groups, missions) as upstream does. A replay of the recorded subscription
        # silently lost bindings made after identification (Marti API), so it is gone.
        self.rabbit_channel = None
        self._decl_channel = None
        self._blocked = False
        self._subscribed = False
        self._chan_opening = False
        self._requeue_unacked()
        if not self._closed:
            self.logger.error(f"RabbitMQ connection lost for {self.client_address[0]} ({error}): delivering the cache, "
                              f"then ending the client session (BATMAN-264-R13)")
            self.close_connection()
        else:
            self._try_end()

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
            self._end_done.set()
            if not self._closed:
                # the session cannot publish or consume any more: end it so the client reconnects clean
                self.logger.error(f"RabbitMQ ioloop of {self.client_address[0]} ended; closing the client session")
                self.shutdown = True
                try:
                    self.request.shutdown(SHUT_RDWR)
                except OSError:
                    pass

    def on_open_error(self, connection, error):
        # Upstream passed no on_open_error_callback: pika's default raised inside the ioloop and killed it.
        self.logger.error(f"RabbitMQ connection failed for {self.client_address[0]}: {error}")
        if self._closed and self._end_args is None:
            self._end_done.set()
            connection.ioloop.stop()
            return
        if self._closed:
            self._try_end()  # the end is draining: try again (bounded by its deadline)
            return
        self._schedule_reconnect()  # BATMAN-264-R4: the broker is down or restarting: keep the session, retry

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

    def _publish_on_ioloop(self, exchange, routing_key, body, meta=None, force=False):
        if self.rabbit_channel and self.rabbit_channel.is_open and not self._blocked:
            if exchange == "cot_parser" and not force and (self.cached_messages or len(self._unacked) >= CACHE_MAX):
                # BATMAN-264-R4b: order and bound. Something older is still cached (a return retry, a reconnect
                # flush in progress) -> queue behind it, never ahead; or the broker has CACHE_MAX publishes
                # unconfirmed -> hold until acks come in, so the unacked set is bounded like the cache.
                self._cache(body, meta)
                return
            if exchange == "cot_parser":
                # BATMAN-264-R5: mandatory -> an unroutable publish comes back through _on_return instead of
                # being dropped (#264 mechanism C); uid/type ride in headers so a returned body keeps its meta
                hdr = {}
                if meta and meta[0]:
                    hdr["x-b264-uid"] = str(meta[0])
                if meta and meta[1]:
                    hdr["x-b264-type"] = str(meta[1])
                self.rabbit_channel.basic_publish(
                    exchange=exchange,
                    routing_key=routing_key,
                    body=body,
                    properties=pika.BasicProperties(expiration=self.app.config.get("OTS_RABBITMQ_TTL"), headers=hdr or None),
                    mandatory=True,
                )
                self._pub_seq += 1
                self._unacked[self._pub_seq] = (body, meta)
            else:
                self.rabbit_channel.basic_publish(
                    exchange=exchange,
                    routing_key=routing_key,
                    body=body,
                    properties=pika.BasicProperties(expiration=self.app.config.get("OTS_RABBITMQ_TTL")),
                )
                self._pub_seq += 1
        elif exchange == "cot_parser":
            self._cache(body, meta)

    # ---- BATMAN-264-R5/R9: cot_parser queue declare, mandatory publish + return, bounded body cache --------
    def _on_decl_channel_open(self, channel):
        self._decl_channel = channel
        channel.add_on_close_callback(self._on_decl_channel_close)
        self._declare_cot_parser()

    def _on_decl_channel_close(self, channel, error):
        # a refused declare must never take the session down: log once, keep publishing (cot_parser's own
        # declare + the return path still apply)
        self._decl_channel = None
        # BATMAN-264-R4: a connection drop closes this channel too; that is not a refusal (the next connection
        # declares again). Only a close while the connection stays open is the broker refusing the declare.
        if not self._decl_refused and not self._closed and self.rabbit_connection and self.rabbit_connection.is_open:
            self._decl_refused = True
            self.logger.error(f"cot_parser queue declare refused ({error}); publishing without it")

    def _declare_cot_parser(self):
        # #264 mechanism C: the transient cot_parser queue is gone after every broker restart until
        # cot_parser re-declares it, and a publish in that window is unroutable (dropped). Declare it here,
        # before this session's first publish, with EXACTLY cot_parser.py:90's arguments (an identical
        # redeclare is accepted, a different one is 406 - probed on the node 2026-10-11) and bind it as
        # cot_parser.py:91 does; the exchanges with app.py:204/210's arguments.
        ch = self._decl_channel
        if ch is None or not ch.is_open:
            if not self._decl_refused and self.rabbit_connection and self.rabbit_connection.is_open:
                self.rabbit_connection.channel(on_open_callback=self._on_decl_channel_open)
            return
        ch.exchange_declare("cot_parser", durable=True, exchange_type="direct")
        ch.exchange_declare("firehose", durable=True, exchange_type="fanout")
        ch.queue_declare(queue="cot_parser")
        ch.queue_bind(exchange="cot_parser", queue="cot_parser", routing_key="cot_parser")

    def _on_blocked(self, connection, method):
        self._blocked = True
        self.logger.error("RabbitMQ blocked this connection (broker alarm): caching cot")

    def _on_unblocked(self, connection, method):
        self._blocked = False
        self._flush_cache()
        if self._end_args is not None:
            self._try_end()

    def _cache(self, body, meta=None):
        # bodies (the serialized cot_parser message), never parsed CoT objects (~25x larger); bounded by
        # count and bytes. Over the bound: the oldest position report (type a-*) whose uid/type has a newer
        # entry goes first, then the oldest entry. Every drop is counted; the upstream log line is kept so
        # ots_logc still counts drops - it now means DROPPED, not cached.
        self.cached_messages.append((body, meta))
        self._cache_bytes += len(body)
        while len(self.cached_messages) > CACHE_MAX or self._cache_bytes > CACHE_MAX_BYTES:
            victim = 0
            seen = set()
            for i in range(len(self.cached_messages) - 1, -1, -1):
                m = self.cached_messages[i][1]
                if m and m[0] and m[1] and str(m[1]).startswith("a-"):
                    if m in seen:
                        victim = i
                    seen.add(m)
            b, _ = self.cached_messages.pop(victim)
            self._cache_bytes -= len(b)
            self._dropped += 1
            if self._dropped == 1 or self._dropped % 100 == 0:
                self.logger.error(f"RabbitMQ channel is closed, not publishing cot: cache full, dropped={self._dropped}")

    def _flush_cache(self):
        if not (self.rabbit_channel and self.rabbit_channel.is_open) or self._blocked:
            return
        pending, self.cached_messages, self._cache_bytes = self.cached_messages, [], 0
        for body, meta in pending:
            self._publish_on_ioloop("cot_parser", "cot_parser", body, meta)

    def _on_return(self, channel, method, properties, body):
        # basic.return: the broker had no queue for it (the mechanism-C window, or a deleted queue). Keep it
        # at the HEAD of the cache, re-declare the queue, and retry the head only, with backoff 2/4/8 s; the
        # rest flushes once a head publish is not returned within 1 s (no return storm).
        h = getattr(properties, "headers", None) or {}
        meta = (h.get("x-b264-uid"), h.get("x-b264-type")) if h else None
        if isinstance(body, bytes):
            body = body.decode("utf-8", errors="replace")
        for k, v in self._unacked.items():   # mark the publish this return belongs to: its ack is not a delivery
            if v[0] == body and k not in self._returned:
                self._returned.add(k)
                break
        self.cached_messages.insert(self._ret_n, (body, meta))  # returns of one burst keep their order
        self._ret_n += 1
        self._cache_bytes += len(body)
        self._head_returned = True
        self._declare_cot_parser()
        if self._retry_timer is None:
            self._schedule_retry()

    def _schedule_retry(self):
        self._retry_n += 1
        self._retry_timer = self.rabbit_connection.ioloop.call_later(min(2 ** self._retry_n, 8), self._retry_head)

    def _retry_head(self):
        self._retry_timer = None
        if not self.cached_messages or not (self.rabbit_channel and self.rabbit_channel.is_open) or self._blocked:
            return
        self._head_returned = False
        self._ret_n = 0
        body, meta = self.cached_messages.pop(0)
        self._cache_bytes -= len(body)
        self._publish_on_ioloop("cot_parser", "cot_parser", body, meta, force=True)  # the head goes ahead of the rest
        self._retry_timer = self.rabbit_connection.ioloop.call_later(1.0, self._after_head)

    def _after_head(self):
        self._retry_timer = None
        if self._head_returned:
            self._schedule_retry()   # the head came back again: wait longer before the next single try
        else:
            self._retry_n = 0
            self._flush_cache()      # the queue is back: everything else may go
            if self._end_args is not None:
                self._try_end()

    def _subscribe(self, ops, binds=None):
        # replay queue_declare / queue_bind / basic_consume recorded by parse_device_info; if the channel is
        # not open yet (a client often sends its first CoT before AMQP is up), do it in on_channel_open
        # instead of never (upstream skipped the subscription for good). Once per session (upstream identifies a
        # session once too: handle_cot runs parse_device_info only while self.uid is unset), replayed on a new
        # channel after a reconnect.
        # BATMAN-264-R10 (review r2 B2-4/A2-2/A2-3, reproduced on node 04): no "busy" refusal any more. The
        # earlier guard left a phone that shares a callsign, or a reconnecting phone, with no downlink at all,
        # and its end then unbound the live holder. Another consumer on the EUD's queues is this device's stale
        # session (R6 reaps it in ~2 min) or a second device with the same callsign; both are subscribed, as
        # upstream did (round-robin on a shared queue). The reconnecting phone is subscribed at once and the
        # stale session's end sees it live (no disconnect, bindings kept). Squatting on an AUTHENTICATED user's
        # names is refused before this (_owned_by_user); an unauthenticated 8088 name has no owner to protect.
        if binds is not None:
            self._sub_binds_pending = list(binds)
        self._sub_ops = ops  # kept for diagnosis; R13 (r3 A3-3) ends the session instead of replaying
        if self._subscribed or self._closed:
            return
        if not (self.rabbit_channel and self.rabbit_channel.is_open):
            self._pending_ops = ops
            return
        ch = self.rabbit_channel

        def declared(frame):
            m = getattr(frame, "method", None)
            n = getattr(m, "consumer_count", 0)
            if n:
                self.logger.info(f"{self.client_address[0]}: queue {getattr(m, 'queue', '?')} shared with {n} other "
                                 f"consumer(s) (a stale session of this EUD, or another device with this callsign)")

        # BATMAN-264-R6 (review r4 B4-11): declares, then the consumers, then the bindings: the old session's
        # end judges "last" by the consumer count, so a reconnecting session is visible before its bindings exist
        rank = {"queue_declare": 0, "basic_consume": 1}
        try:
            for name, a, k in sorted(ops, key=lambda o: rank.get(o[0], 2)):
                if name == "queue_declare":
                    ch.queue_declare(*a, callback=declared, **k)
                else:
                    getattr(ch, name)(*a, **k)
        except Exception as e:
            self.logger.error(f"subscription failed ({e}); the channel close path handles it")
            self._release_admit()
            return
        self._subscribed = True
        self._sub_binds = list(self._sub_binds_pending)
        self.logger.info(f"subscribed {self.uid}/{self.callsign} for {self.client_address[0]}")
        self._release_admit()  # BATMAN-264-R16: admitted and placed: the next admission may go

    # ---- BATMAN-264-R4/R4b: publisher confirms (at-least-once) and reconnect on the same ioloop ---------------
    def _on_confirm(self, frame):
        # Basic.Ack / Basic.Nack from the broker, delivery_tag = the n-th publish on this channel; multiple=True
        # covers every tag up to and including it. An acked cot_parser publish is delivered (unless it was
        # returned first: then it is already back in the cache and the ack means nothing). A nack puts the
        # bodies back at the head of the cache. Duplicates are possible (a publish acked after we re-cached it on
        # a close): at-least-once, as decided.
        m = getattr(frame, "method", None)
        tag = getattr(m, "delivery_tag", 0)
        keys = [k for k in self._unacked if (k <= tag if getattr(m, "multiple", False) else k == tag)]
        nack = getattr(m, "NAME", "").endswith("Nack")
        pos = 0
        for k in keys:
            body, meta = self._unacked.pop(k)
            if k in self._returned:
                self._returned.discard(k)
            elif nack:
                self.cached_messages.insert(pos, (body, meta))  # nacked bodies keep their publish order
                pos += 1
                self._cache_bytes += len(body)
        if nack and keys and self._retry_timer is None:
            self._schedule_retry()
        elif keys and self.cached_messages and self._retry_timer is None and len(self._unacked) < CACHE_MAX:
            self._flush_cache()  # bodies held back by the unacked bound may go now
        if keys and self._end_args is not None:
            self._try_end()  # BATMAN-264-R4b: a session end waits for its acks

    def _requeue_unacked(self):
        # the channel/connection is gone: everything not acked goes back to the cache, in publish order, at the
        # head (older than anything cached since); returned ones are already there
        pending = [v for k, v in self._unacked.items() if k not in self._returned]
        self._unacked.clear()
        self._returned.clear()
        for body, meta in reversed(pending):
            self.cached_messages.insert(0, (body, meta))
            self._cache_bytes += len(body)

    def _schedule_reconnect(self):
        if (self._closed and not self._end_args) or self._reconnect_timer is not None or self._ioloop is None:
            return
        c = self.rabbit_connection
        if c is not None and (c.is_open or not c.is_closed):
            return  # open, or still opening/closing: never a second connection (review r2 A2-9)
        self._reconnect_n += 1
        delay = min(2 ** (self._reconnect_n - 1), 30) * (0.75 + random.random() / 2)  # jitter: no lockstep
        self.logger.error(f"RabbitMQ reconnect for {self.client_address[0]} in {delay:.1f} s (attempt {self._reconnect_n})")
        self._reconnect_timer = self._ioloop.call_later(delay, self._reconnect)

    def _reconnect(self):
        self._reconnect_timer = None
        if self._closed and not self._end_args:
            return
        try:
            params = self.rabbit_connection.params
            self.rabbit_connection = pika.SelectConnection(
                params,
                self.on_connection_open,
                on_open_error_callback=self.on_open_error,
                on_close_callback=self.on_close,
                custom_ioloop=self._ioloop,
            )
        except Exception as e:
            self.logger.error(f"RabbitMQ reconnect failed to start: {e}")
            self._schedule_reconnect()

    # ---- BATMAN-264-R6: a vanished peer, and a session end that must not cut a live session of the same EUD --
    def _keepalive(self, sock):
        # Upstream never wrote to an idle client and set no keepalive, so a peer that vanished (HaLow drop, phone
        # off, roaming) kept its session, its consumers on the shared <uid>/<callsign> queues and its memory for
        # ever (measured: still consuming after 30 s of a black-holed port, deliveries lost to it). Probe after 45 s
        # idle, every 15 s, 4 misses; TCP_USER_TIMEOUT also bounds unacknowledged writes. ~2 min to a dead peer.
        try:
            sock.setsockopt(socket_mod.SOL_SOCKET, socket_mod.SO_KEEPALIVE, 1)
            sock.setsockopt(socket_mod.IPPROTO_TCP, socket_mod.TCP_KEEPIDLE, KEEPALIVE_IDLE)
            sock.setsockopt(socket_mod.IPPROTO_TCP, socket_mod.TCP_KEEPINTVL, KEEPALIVE_INTVL)
            sock.setsockopt(socket_mod.IPPROTO_TCP, socket_mod.TCP_KEEPCNT, KEEPALIVE_CNT)
            sock.setsockopt(socket_mod.IPPROTO_TCP, socket_mod.TCP_USER_TIMEOUT, KEEPALIVE_USER_TIMEOUT_MS)
        except (OSError, AttributeError) as e:
            self.logger.error(f"keepalive not set on the client socket: {e}")

    def _end_session(self, uid, body):
        # ioloop thread. cot_parser's send_disconnect_cot (cot_parser.py:944-1033) unbinds <uid> from EVERY group
        # and mission on a disconnect message, whoever else still holds that queue, and upstream's close also
        # unbound the dms/groups/missions bindings unconditionally: when a stale session of an EUD ended, the
        # EUD's live session (same uid, reconnected phone) lost all its bindings (measured: 10/10 -> 0/10).
        # Review round 2 (all reproduced on node 04, rc wsl.8):
        #  - B2-1/A2-2c: a session that never subscribed (a refused name, a refused owner, a relay) published a
        #    disconnect and unbound the recorded bindings, i.e. the LIVE session's (0/10). It placed nothing, so it
        #    removes nothing and tells cot_parser nothing about that uid (a relay / never-identified session keeps
        #    upstream's disconnect: it has no queues).
        #  - "last" is judged per queue: the <uid> queue's consumers decide the disconnect and its bindings; the
        #    <callsign> queue's binding is removed only when nobody else consumes it (a second device with the
        #    same callsign keeps its DMs).
        #  - A2-1 (cot_parser crash loop, reproduced under load): the queues of an AUTHENTICATED (8089) session are
        #    never deleted: cot_parser's 8089 disconnect branch BINDS <uid> to the user's groups
        #    (cot_parser.py:989) and a deleted queue made that a 404, a channel close, an exception out of
        #    basic_nack and a container exit, with the unacked disconnect redelivered first: a crash loop. F3's
        #    cleanup applies to 8088 sessions only (no user: cot_parser's 8088 branch does not bind). Their
        #    orphans are bounded by the enrolled devices.
        ch = self.rabbit_channel
        for tag in list(getattr(ch, "consumer_tags", []) or []):
            try:
                ch.basic_cancel(tag)
            except Exception as e:
                self.logger.error(f"basic_cancel failed: {e}")

        binds = list(self._sub_binds)
        authenticated = self.user is not None

        def close():
            self._final_close = True
            ch.close()  # on_channel_close (CloseOk) -> _done()

        def publish_disconnect():
            ch.basic_publish(
                exchange="cot_parser",
                body=body,
                routing_key="cot_parser",
                properties=pika.BasicProperties(expiration=self.app.config.get("OTS_RABBITMQ_TTL")),
            )

        if not binds:
            if self._relay or not uid:
                try:
                    publish_disconnect()  # upstream's path; cot_parser ignores a uid-less one
                finally:
                    close()
                return
            if self._squat_logged or not _valid_name(uid):
                close()  # refused as another user's device, or not a usable name: never speak for that uid (r2 B2-1)
                return

            def counted(frame):
                # review r3 B3-10: an identified session whose subscription never happened (it left before AMQP was
                # up) left its EUD row "Connected" for ever. Its disconnect is sent when nobody consumes <uid> (a live
                # session of the uid would lose its bindings to cot_parser's disconnect, r2 B2-1). The declare is a
                # normal (not passive) one, as the subscription's: a missing queue must not close the channel.
                try:
                    if not getattr(getattr(frame, "method", None), "consumer_count", 0) and not self._newer_session(uid):
                        publish_disconnect()
                        if self.user is None and not self._uid_has_owner(uid):  # r5 B5-11: no 24 h empty orphan
                            ch.queue_delete(queue=uid, if_unused=True, if_empty=True)
                    else:
                        self.logger.info(f"another session of {uid} is live: no disconnect")
                finally:
                    close()

            try:
                ch.queue_declare(queue=uid, callback=counted)
            except Exception as e:
                self.logger.error(f"declare of {uid} at the end failed: {e}")
                close()
            return

        names = [uid] + ([self.callsign] if self._cs_queue and self.callsign and self.callsign != uid else [])
        seen = {}

        def finish():
            try:
                cu, mu = seen[uid]
                cc, mc = seen.get(self.callsign, (0, 0)) if len(names) == 2 else (cu, mu)
                if cu or self._newer_session(uid):  # R17 (r6 A6-4/B6-6): its new session may not consume yet
                    self.logger.info(f"another session of {uid} is live: no disconnect, bindings kept")
                    return
                publish_disconnect()
                keep_cs = len(names) == 2 and cc > 0
                self.unbind_rabbitmq_queues(uid, [b for b in binds if not (keep_cs and b["queue"] == self.callsign)])
                if authenticated:
                    return  # A2-1: cot_parser binds <uid> on this disconnect; the queues stay
                # F3, 8088 only: idle empty queues go, the <uid> queue LAST (a broadcast landing in it between the
                # check and the delete is refused with 406, which closes the channel and drops every later delete)
                if len(names) == 2 and not cc and not mc:
                    ch.queue_delete(queue=self.callsign, if_unused=True, if_empty=True)
                if not mu and not self._uid_has_owner(uid):  # review r3 B3-7
                    ch.queue_delete(queue=uid, if_unused=True, if_empty=True)
            finally:
                close()

        def declared(frame):
            m = getattr(frame, "method", None)
            seen[names[len(seen)]] = (getattr(m, "consumer_count", 0), getattr(m, "message_count", 0))
            if len(seen) < len(names):
                ch.queue_declare(queue=names[len(seen)], callback=declared)  # r5: not passive (see _end_session)
            else:
                finish()

        try:
            # BATMAN-264 (review r5 A5-3/B5-5): NOT passive. The per-EUD queues are transient: after a broker restart,
            # or after the other device of a shared callsign deleted the callsign queue, a passive declare was a 404
            # that closed the channel (no disconnect, a ghost "Connected" row). A normal declare re-creates an empty
            # queue (R15 expires it) and reports the consumers the same way.
            ch.queue_declare(queue=names[0], callback=declared)
        except Exception as e:
            self.logger.error(f"declare of {uid} at the end failed: {e}")
            close()

    # ---- BATMAN-264-R17 (review r6 A6-2/A6-4/B6-6): one live session per device and listener ----------------------
    def _reg_path(self, uid):
        port = getattr(self.server, "server_address", ("", 0))[1]
        return os.path.join(SESS_DIR, f"{port}-{hashlib.sha256(str(uid).encode('utf-8', 'replace')).hexdigest()[:32]}")

    def _reg_read(self, uid):
        # -> (pid, ip, user) of the session that last claimed uid on this listener, if that process still lives
        try:
            with open(self._reg_path(uid), encoding="ascii") as f:
                pid, start, ip, user = f.read().split()[:4]
            pid, start = int(pid), int(start)
        except (OSError, ValueError, UnicodeDecodeError):
            return None
        if pid <= 1 or _proc_start(pid) != start:
            return None  # gone, or the pid was reused
        return pid, ip, user

    def _claim(self, uid):
        # Handler thread, at identification, after the ownership checks. When the RTO walks out of range and back,
        # each phone reconnects while its previous session is still open (no FIN reached the server; R6 reaps it in
        # ~2 min): 16 zombies + 16 reconnects, and a second flap inside that window 48 sessions, more than the
        # container holds (review r6 A6-2). The zombie also takes every other downlink message meanwhile (auto_ack,
        # round-robin on the shared <uid> queue). The device is back, so its previous session ends now (SIGUSR1 ->
        # _on_supersede; its end sees this session and sends no disconnect, keeps the bindings). Only the SAME device:
        # on 8089 the same OTS user; on 8088 (unauthenticated) the same client address as well, so a client elsewhere
        # on the mesh naming this uid ends nothing. A phone that comes back through another node (a new address)
        # keeps R6's reap of the old session (as before).
        try:
            os.makedirs(SESS_DIR, mode=0o700, exist_ok=True)
            me = os.getpid()
            user = str(self.user.id) if self.user else "-"
            old = self._reg_read(uid)
            if old is not None and old[0] != me:
                if self.is_ssl:
                    same = user != "-" and old[2] == user
                else:
                    same = user == "-" and old[2] == "-" and old[1] == self.client_address[0]
                if not same:
                    self.logger.info(f"{self.client_address[0]}: uid {uid} has a live session from {old[1]} (pid "
                                     f"{old[0]}); both kept (BATMAN-264-R17)")
                    return
                os.kill(old[0], signal.SIGUSR1)
                self.logger.info(f"{self.client_address[0]}: device {uid} is back; its previous session (pid "
                                 f"{old[0]}) is ended (BATMAN-264-R17)")
            path = self._reg_path(uid)
            with open(f"{path}.{me}", "w", encoding="ascii") as f:
                f.write(f"{me} {_proc_start(me)} {self.client_address[0]} {user}\n")
            os.replace(f"{path}.{me}", path)
            self._claimed = True
        except Exception as e:
            self.logger.error(f"BATMAN-264-R17: device registry for {uid} unusable ({type(e).__name__}: {e}); "
                              f"a previous session is left to R6")

    def _newer_session(self, uid):
        # the end (ioloop thread): another live session has claimed this uid on this listener. Its subscription may
        # not consume yet (a broker restart: the late end of the old session, review r6 A6-4), so the consumer count
        # alone would publish a disconnect and unbind the phone's new session.
        old = self._reg_read(uid) if uid else None
        return old is not None and old[0] != os.getpid()

    def _unclaim(self):
        if not self._claimed or not self.uid:
            return
        old = self._reg_read(self.uid)
        if old is not None and old[0] == os.getpid():
            try:
                os.remove(self._reg_path(self.uid))
            except OSError:
                pass

    def _on_supersede(self, signum, frame):
        # SIGUSR1 from this device's newer session (_claim). Runs in this child's main thread between bytecodes: a
        # flag and the socket shutdown only; recv returns and handle() runs the normal end.
        self._superseded = True
        self.logger.info(f"{self.client_address[0]}: session of {self.uid} superseded by the device's new session "
                         f"(BATMAN-264-R17)")
        try:
            self.request.shutdown(SHUT_RDWR)
        except OSError:
            pass

    def _fi(self, uid, stage):
        # BATMAN-264 (review r6 B6-2): white-box fault injection for exception-264. Since r5 no client input makes
        # identification or a message raise, so the R14 and per-message handlers have no natural trigger left.
        # FI_FILE (this container's private /tmp: root through docker exec, or this container's own uid 1000) holds
        # "<stage> <uid>"; the first matching message of a session then raises once. Absent file: one failed open.
        if self._fi_done or not uid:
            return
        try:
            with open(FI_FILE, encoding="utf-8") as f:
                want = f.read().split()
        except (OSError, UnicodeDecodeError):
            return
        if want == [stage, uid]:
            self._fi_done = True
            raise RuntimeError(f"BATMAN-264 fault injection ({stage})")

    def _minimal_eud_row(self, uid):
        # BATMAN-264-R14/R10 (review r5): the smallest row cot_parser's FK needs: the uid, "Connected", this session's
        # user, and the callsign only if no other device holds it (euds.callsign is UNIQUE). Never raises.
        with self.app.app_context():
            for with_cs in (True, False):
                try:
                    db.session.rollback()
                    row = db.session.execute(select(EUD).filter_by(uid=uid)).first()
                    if row is not None:
                        self._row_next = 0.0
                        return True
                    e = EUD()
                    e.uid = uid
                    e.last_status = "Connected"
                    e.user_id = self.user.id if self.user else None
                    if with_cs and self.callsign:
                        e.callsign = str(self.callsign)[:255]
                    db.session.add(e)
                    db.session.commit()
                    self._row_next = 0.0
                    return True
                except Exception as ex:
                    db.session.rollback()
                    if not with_cs:
                        self.logger.error(f"minimal EUD row of {uid} failed too: {type(ex).__name__}: {ex}; retried in "
                                          f"30 s (BATMAN-264-R14)")
        self._row_next = time.monotonic() + 30
        return False

    def _uid_has_owner(self, uid):
        # review r3 B3-7: an 8088 session of a uid that an OTS user's device (8089) holds as well must not delete
        # <uid>: cot_parser's 8089 disconnect BINDS it (cot_parser.py:989), a deleted queue there is the A2-1 crash
        # loop. One lookup at the end; when the database does not answer the queue is kept (fail-safe).
        try:
            with self.app.app_context():
                row = db.session.execute(select(EUD.user_id).filter(EUD.uid == uid)).first()
            return row is not None and row[0] is not None
        except Exception as e:
            self.logger.error(f"owner lookup of {uid} at the end failed ({e}); queue kept")
            return True

    def on_message(self, unused_channel, basic_deliver, properties, body):
        try:
            body = json.loads(body)
            if body["uid"] != self.uid:
                self.request.send(body["cot"].encode())
        except BaseException as e:
            self.logger.error(f"{self.callsign}: {e}, closing socket")
            self.close_connection()
            self.logger.error(traceback.format_exc())

    def handle_auth(self, auth: str):
        self.logger.debug(auth)
        if auth:
            auth = BeautifulSoup(auth, "xml")
        if self.is_ssl and not self.is_authenticated and (auth or self.common_name):
            user = None
            with self.app.app_context():
                if auth:
                    cot = auth.find("cot")
                    if cot:
                        username = cot.attrs["username"]
                        password = cot.attrs["password"]
                        uid = cot.attrs["uid"]

                        if self.app.config.get("OTS_ENABLE_LDAP"):
                            result = ldap_manager.authenticate(username, password)

                            if result.status == AuthenticationResponseStatus.success:
                                # Keep this import here to avoid a circular import when OTS is started
                                from opentakserver.blueprints.ots_api.ldap_api import save_user

                                self.user = save_user(
                                    result.user_dn,
                                    result.user_id,
                                    result.user_info,
                                    result.user_groups,
                                )

                                try:
                                    eud = db.session.execute(
                                        db.session.query(EUD).filter_by(uid=uid)
                                    ).first()[0]
                                    self.logger.debug(
                                        "Associating EUD uid {} to user {}".format(
                                            eud.uid, self.user.username
                                        )
                                    )
                                    eud.user_id = self.user.id
                                    db.session.commit()
                                except:
                                    self.logger.debug(
                                        "This is a new eud: {} {}".format(uid, self.user.username)
                                    )
                                    eud = EUD()
                                    eud.uid = uid
                                    eud.user_id = self.user.id
                                    eud.callsign = self.callsign
                                    db.session.add(eud)
                                    db.session.commit()

                            else:
                                self.close_connection()
                                return

                        else:
                            user = self.app.security.datastore.find_user(username=username)
                elif self.common_name:
                    user = self.app.security.datastore.find_user(username=self.common_name)

                if not user:
                    self.logger.warning("User {} does not exist".format(self.common_name))
                    self.close_connection()
                    return
                elif not user.active:
                    self.logger.warning("User {} is deactivated, disconnecting".format(username))
                    self.close_connection()
                    return
                elif self.common_name:
                    self.logger.info("{} is ID'ed by cert".format(user.username))
                    self.is_authenticated = True
                    self.user = user
                elif verify_password(password, user.password):
                    self.logger.info("Successful login from {}".format(username))
                    self.is_authenticated = True
                    self.user = user
                    try:
                        eud = db.session.execute(db.session.query(EUD).filter_by(uid=uid)).first()[
                            0
                        ]
                        self.logger.debug(
                            "Associating EUD uid {} to user {}".format(eud.uid, user.username)
                        )
                        eud.user_id = user.id
                        db.session.commit()
                    except:
                        self.logger.debug("This is a new eud: {} {}".format(uid, user.username))
                        eud = EUD()
                        eud.uid = uid
                        eud.user_id = user.id
                        db.session.add(eud)
                        db.session.commit()

                else:
                    self.logger.warning("Wrong password for user {}".format(username))
                    self.close_connection()
                    return

    def handle_cot(self, cot):
        self.logger.debug(cot)
        event = BeautifulSoup(cot, "xml").find("event")

        # If this client is connected via ssl, make sure they're authenticated
        # before accepting any data from them
        if self.is_ssl and not self.is_authenticated:
            self.logger.warning("EUD isn't authenticated, ignoring")
            return

        if self.pong(event):
            return

        self._fi(event.attrs.get("uid") if event else None, "message")  # r6 B6-2: test-only, see _fi
        if self.uid and self._row_next and time.monotonic() >= self._row_next:
            self._minimal_eud_row(self.uid)  # BATMAN-264-R14 (r6): the device's row is still missing

        if event and not self.uid:
            try:
                self.parse_device_info(event)
            except Exception as e:
                # BATMAN-264-R14 (review r4 A4-7/B4-2, measured on rc wsl.12): parse_device_info sets self.uid before
                # it writes the EUD row; an exception in between (a CoT without start, a missing role, a DB error)
                # left the uid set and the row unwritten, so the session never identified again and cot_parser's FK
                # dropped every later CoT. The uid is reset: the next report identifies again; this CoT is still
                # published (cot_parser decides whether it can be stored).
                self.logger.error(f"{self.client_address[0]}: identification raised {type(e).__name__}: {e}; "
                                  f"identifying again on the next report (BATMAN-264-R14)")
                self.logger.debug(traceback.format_exc())
                self._ident_failures += 1
                if self._ident_failures < 3:
                    self.uid = None
                else:
                    # BATMAN-264-R14 (review r5 A5-2/B5-2): an identification that keeps raising re-ran on every CoT
                    # (a new postgres connection each, measured offline: 10 000 runs); after 3 the session keeps
                    # this uid, its minimal row is written once, and identification is not tried again
                    self.logger.error(f"{self.client_address[0]}: identification failed 3 times; keeping uid {self.uid}, "
                                      f"minimal row (BATMAN-264-R14)")
                    if self.uid:
                        self._minimal_eud_row(self.uid)
            # Close the DB connection once the EUD is authenticated and identified
            with self.app.app_context():
                db.session.close()
                db.engine.dispose()

        self.publish_cot(event)

    def publish_cot(self, event):
        if not event:
            return

        # BATMAN-264: bodies are built here (the DB-bound self.user is thread-local to this thread), the
        # publishes run on the ioloop thread. If the loop is gone: upstream's "channel closed" path.
        fh = json.dumps({"uid": self.uid, "cot": str(event)})
        cp = json.dumps({"uid": self.uid, "cot": str(event), "user_id": self.user.id if self.user else None})
        meta = (self.uid, event.attrs.get("type") if hasattr(event, "attrs") else None)  # BATMAN-264-R9

        def _both():
            # Route all CoTs to the firehose exchange for plugins and users that connect directly to RabbitMQ
            self._publish_on_ioloop("firehose", "", fh)
            # Route all cots to the cot_parser direct exchange to be processed by a pool of cot_parser processes
            self._publish_on_ioloop("cot_parser", "cot_parser", cp, meta)

        if not self._io(_both):
            self._cache(cp, meta)

    def parse_device_info(self, event):
        link = event.find("link")
        fileshare = event.find("fileshare")

        # EUDs running the Meshtastic and dmrcot plugins can relay messages from their RF networks to the server
        # so we want to use the UID of the "off grid" EUD, not the relay EUD
        contact = event.find("contact")
        takv = event.find("takv")
        if takv or contact:
            uid = event.attrs.get("uid")
        else:
            return

        contact = event.find("contact")

        # Only assume it's an EUD if it's got a <contact> tag
        if contact and uid and not uid.endswith("ping") and (self.user or not self.is_ssl):
            self.uid = uid
            self._fi(uid, "ident")  # r6 B6-2: test-only, see _fi (raises after the uid is set: R14's reset is exercised)
            device = operating_system = platform = version = None
            if takv:
                device = takv.attrs["device"] if "device" in takv.attrs else None
                operating_system = takv.attrs["os"] if "os" in takv.attrs else None
                platform = takv.attrs["platform"] if "platform" in takv.attrs else None
                version = takv.attrs["version"] if "version" in takv.attrs else None

            if "callsign" in contact.attrs:
                self.callsign = contact.attrs["callsign"]

                # Declare a RabbitMQ Queue for this uid and join the 'dms' and 'cot' exchanges
                _ch = _OpRecorder()  # BATMAN-264: channel calls recorded here, run on the ioloop by _subscribe
                if not _valid_name(self.uid):  # BATMAN-264-R10
                    self.logger.error(
                        f"refusing the subscription of {self.client_address[0]}: uid is not a usable queue name "
                        f"(empty, >255 bytes, amq.*, a system name or not printable); no EUD row, so cot_parser "
                        f"stores nothing from it")
                    return
                if self.is_ssl:
                    owned, cs_owned = self._owned_by_other_user(self.uid), False
                else:
                    owned, cs_owned = self._owned_by_user(self.uid, self.callsign)
                if owned is None:  # BATMAN-264-R10: database down: identify again on the next report
                    self.uid = None
                    return
                # BATMAN-264-R10 (review r4 A4-2/B4-1, the user's decision 2026-10-12): a callsign that is not a usable
                # queue name, or that belongs to an authenticated user's device, is not used as a queue; the device is
                # still subscribed by its own uid and RECORDED (its EUD row is written below). Refusing the whole
                # device left it without a row, and cot_parser's FK dropped every CoT it sent (measured on rc wsl.12).
                self._cs_queue = _valid_name(self.callsign) and not cs_owned
                if not self._cs_queue:
                    self.logger.error(
                        f"{self.client_address[0]}: callsign {self.callsign!r} is not used as a queue (not a usable "
                        f"name, or an authenticated user's device's name); subscribed by uid {self.uid} only, recorded "
                        f"(BATMAN-264-R10)")
                if owned:  # BATMAN-264-R10 (review F8/M7)
                    # an unauthenticated 8088 client naming an authenticated user's device, or (review r3 B3-5) an
                    # 8089 user claiming the uid of ANOTHER user's device: no subscription (it would receive that
                    # user's DMs and group traffic) and no EUD row update (it would take the device from its user;
                    # measured on rc wsl.10: user_id 1 -> 2). Residual, stated: the CoT this session sends still
                    # carry the claimed uid and cot_parser may store them (review r3 A3-9).
                    if not self._squat_logged:
                        self._squat_logged = True
                        if self.is_ssl:
                            self.logger.error(
                                f"refusing the subscription of {self.client_address[0]} (user {self.common_name}): uid "
                                f"{self.uid} belongs to another user's device (BATMAN-264-R10)")
                        else:
                            self.logger.error(
                                f"refusing the subscription of {self.client_address[0]} on the plaintext listener: "
                                f"uid/callsign {self.uid}/{self.callsign} belong to an authenticated user's device")
                    return
                self._relay = platform in ("OpenTAK ICU", "Meshtastic", "DMRCOT")  # BATMAN-264: no queues of its own
                if (
                    platform != "OpenTAK ICU"
                    and platform != "Meshtastic"
                    and platform != "DMRCOT"
                ):

                    self.logger.debug(f"Declaring queue for {self.callsign} {self.uid}")
                    if self._cs_queue:  # BATMAN-264-R10 (r4)
                        _ch.queue_declare(queue=self.callsign)
                    _ch.queue_declare(queue=self.uid)

                    with self.app.app_context():
                        if self.is_ssl:
                            try:
                                group_memberships = db.session.execute(
                                    db.session.query(GroupUser).filter_by(
                                        user_id=self.user.id, direction=Group.OUT
                                    )
                                ).all()
                            except Exception as e:  # BATMAN-264 (review r6 A6-6/B6-4): not a strike, as R10's lookup
                                self.logger.error(f"group lookup of {self.uid} failed ({type(e).__name__}: {e}); "
                                                  f"identifying again on the next report")
                                db.session.rollback()
                                self.uid = None
                                return
                            if not group_memberships:
                                self.logger.debug(
                                    f"{self.callsign} doesn't belong to any groups, adding them to the __ANON__ group"
                                )
                                _ch.queue_bind(
                                    exchange="groups", queue=self.uid, routing_key="__ANON__.OUT"
                                )
                                if {
                                    "exchange": "groups",
                                    "routing_key": "__ANON__.OUT",
                                    "queue": self.uid,
                                } not in self.bound_queues:
                                    self.bound_queues.append(
                                        {
                                            "exchange": "groups",
                                            "routing_key": "__ANON__.OUT",
                                            "queue": self.uid,
                                        }
                                    )

                            elif group_memberships and self.is_ssl:
                                for membership in group_memberships:
                                    membership: GroupUser = membership[0]
                                    self.group_memberships.append(membership)

                                    if membership.enabled:
                                        _ch.queue_bind(
                                            exchange="groups",
                                            queue=self.uid,
                                            routing_key=f"{membership.group.name}.OUT",
                                        )

                                    if {
                                        "exchange": "groups",
                                        "routing_key": f"{membership.group.name}.OUT",
                                        "queue": self.uid,
                                    } not in self.bound_queues:
                                        self.bound_queues.append(
                                            {
                                                "exchange": "groups",
                                                "routing_key": f"{membership.group.name}.OUT",
                                                "queue": self.uid,
                                            }
                                        )

                        _ch.queue_bind(
                            exchange="missions", routing_key="missions", queue=self.uid
                        )
                        if {
                            "exchange": "missions",
                            "routing_key": "missions",
                            "queue": self.uid,
                        } not in self.bound_queues:
                            self.bound_queues.append(
                                {
                                    "exchange": "missions",
                                    "routing_key": "missions",
                                    "queue": self.uid,
                                }
                            )

                        # The DMs queue also binds by callsign since the <dest> tag in CoT messages can be by callsign instead of UID
                        _ch.queue_bind(
                            exchange="dms", queue=self.uid, routing_key=self.uid
                        )
                        if self._cs_queue:  # BATMAN-264-R10 (r4)
                            _ch.queue_bind(
                                exchange="dms", queue=self.callsign, routing_key=self.callsign
                            )

                        if {
                            "exchange": "dms",
                            "routing_key": self.uid,
                            "queue": self.uid,
                        } not in self.bound_queues:
                            self.bound_queues.append(
                                {"exchange": "dms", "routing_key": self.uid, "queue": self.uid}
                            )

                        if self._cs_queue and {  # BATMAN-264-R10 (r4)
                            "exchange": "dms",
                            "routing_key": self.callsign,
                            "queue": self.callsign,
                        } not in self.bound_queues:
                            self.bound_queues.append(
                                {
                                    "exchange": "dms",
                                    "routing_key": self.callsign,
                                    "queue": self.callsign,
                                }
                            )

                        if not self.is_ssl:
                            self.logger.debug(
                                f"{self.callsign} is connected via TCP, adding them to the __ANON__ group"
                            )
                            _ch.queue_bind(
                                exchange="groups", queue=self.uid, routing_key="__ANON__.OUT"
                            )
                            self.bound_queues.append(
                                {
                                    "exchange": "groups",
                                    "routing_key": "__ANON__.OUT",
                                    "queue": self.uid,
                                }
                            )

                        if self._cs_queue:  # BATMAN-264-R10 (r4)
                            _ch.basic_consume(
                                queue=self.callsign, on_message_callback=self.on_message, auto_ack=True
                            )
                        _ch.basic_consume(
                            queue=self.uid, on_message_callback=self.on_message, auto_ack=True
                        )
                if _ch.ops:
                    self._sub_wanted = True  # BATMAN-264-R16: the admission lock is released once this is placed
                    self._claim(self.uid)  # BATMAN-264-R17: the device's previous session on this listener ends
                    self._io(self._subscribe, _ch.ops, list(self.bound_queues))

            if "phone" in contact.attrs and contact.attrs["phone"]:
                self.phone_number = contact.attrs["phone"]

            # BATMAN-264-R14 (review r5 A5-2/B5-1): the row is written whatever the metadata looks like
            try:
                with self.app.app_context():
                    __group = event.find("__group")
                    team = Team()

                    if __group:
                        team.name = bleach.clean(__group.attrs["name"])

                        try:
                            chatroom = db.session.execute(
                                select(Chatroom).filter(Chatroom.name == team.name)
                            ).first()[0]
                            team.chatroom_id = chatroom.id
                        except TypeError:
                            chatroom = None

                        try:
                            db.session.add(team)
                            db.session.commit()
                        except sqlalchemy.exc.IntegrityError:
                            db.session.rollback()
                            team = db.session.execute(
                                select(Team).filter(Team.name == __group.attrs["name"])
                            ).first()[0]
                            if not team.chatroom_id and chatroom:
                                team.chatroom_id = chatroom.id
                                db.session.execute(
                                    update(Team)
                                    .filter(Team.name == chatroom.id)
                                    .values(chatroom_id=chatroom.id)
                                )

                    try:
                        eud = db.session.execute(select(EUD).filter_by(uid=uid)).first()[0]
                    except:
                        eud = EUD()

                    eud.uid = uid
                    if self.callsign:
                        # BATMAN-264-R10 (review r4): euds.callsign is UNIQUE. A callsign held by ANOTHER device's row made
                        # the insert fail and the fallback update match nothing: no row, every CoT of this device dropped
                        # by cot_parser's FK (upstream too; measured on node 04: the second device of a shared callsign).
                        # The device is recorded under its uid without a callsign column (the CoT keep their callsign).
                        clash = db.session.execute(
                            select(EUD.uid).filter(EUD.callsign == self.callsign).filter(EUD.uid != uid)
                        ).first()
                        if clash is None:
                            eud.callsign = self.callsign
                        else:
                            self.logger.error(f"{self.client_address[0]}: callsign {self.callsign!r} is another device's "
                                              f"({clash[0]}); {uid} recorded without it (BATMAN-264-R10)")
                    if device:
                        eud.device = str(device)[:255]  # BATMAN-264-R14 (r5)

                    eud.os = (operating_system or None) and str(operating_system)[:255]  # BATMAN-264-R14 (r5): String(255)
                    eud.platform = (platform or None) and str(platform)[:255]
                    eud.version = (version or None) and str(version)[:255]
                    eud.phone_number = _phone_int(self.phone_number)  # BATMAN-264-R14 (r5): BigInteger column
                    try:  # BATMAN-264-R14 (r5): a missing or odd start must not cost the row
                        eud.last_event_time = datetime_from_iso8601_string(event.attrs["start"])
                    except Exception:
                        eud.last_event_time = None
                    eud.last_status = "Connected"
                    eud.user_id = self.user.id if self.user else None

                    # Set a Meshtastic ID for TAK EUDs to be identified by in the Meshtastic network
                    if not eud.meshtastic_id and eud.platform != "Meshtastic":
                        meshtastic_id = "{:x}".format(int.from_bytes(os.urandom(4), "big"))
                        while len(meshtastic_id) < 8:
                            meshtastic_id = "0" + meshtastic_id
                        eud.meshtastic_id = int(meshtastic_id, 16)
                    elif not eud.meshtastic_id and eud.platform == "Meshtastic":
                        try:
                            eud.meshtastic_id = int(takv.attrs["meshtastic_id"], 16)
                        except:
                            meshtastic_id = "{:x}".format(int.from_bytes(os.urandom(4), "big"))
                            while len(meshtastic_id) < 8:
                                meshtastic_id = "0" + meshtastic_id
                            eud.meshtastic_id = int(meshtastic_id, 16)

                    # Get the Meshtastic device's mac address or generate a random one for TAK EUDs
                    if takv and "macaddr" in takv.attrs:
                        eud.meshtastic_macaddr = takv.attrs["macaddr"]
                    else:
                        eud.meshtastic_macaddr = base64.b64encode(os.urandom(6)).decode("ascii")

                    if __group:
                        eud.team_id = team.id
                        eud.team_role = bleach.clean(__group.attrs.get("role") or "")[:255] or None  # BATMAN-264-R14 (r5)

                    try:
                        db.session.add(eud)
                        db.session.commit()
                    except sqlalchemy.exc.IntegrityError:
                        db.session.rollback()
                        r = db.session.execute(
                            update(EUD).where(EUD.uid == eud.uid).values(**eud.serialize())
                        )
                        db.session.commit()
                        if not getattr(r, "rowcount", 1):
                            # BATMAN-264-R10 (review r5 A5-4/B5-6): no row for this uid and the insert hit a UNIQUE
                            # callsign taken in between (two devices identifying together): recorded without it
                            self._minimal_eud_row(uid)

                    # If the RabbitMQ channel is open, publish the EUD info to socketio to be displayed on the web UI map.
                    # Also save the EUD's info for on_channel_open to publish
                    self.eud = eud
                    if self.rabbit_channel:
                        message = {
                            "method": "emit",
                            "event": "eud",
                            "data": eud.to_json(),
                            "namespace": "/socket.io",
                            "room": None,
                            "skip_sid": None,
                            "callback": None,
                            "binary": False,
                            "host_id": uuid.uuid4().hex,
                        }
                        self._io(self._publish_on_ioloop, "flask-socketio", "", json.dumps(message).encode())  # BATMAN-264
            except Exception as e:
                self.logger.error(f"{self.client_address[0]}: EUD row of {uid} not written ({type(e).__name__}: {e}); "
                                  f"writing a minimal row so its CoT are recorded (BATMAN-264-R14)")
                self.logger.debug(traceback.format_exc())
                self._minimal_eud_row(uid)

    def unbind_rabbitmq_queues(self, uid, binds):  # BATMAN-264: ioloop thread only, snapshot of the bindings
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

            for bind in binds:
                self.rabbit_channel.queue_unbind(
                    exchange=bind["exchange"], queue=bind["queue"], routing_key=bind["routing_key"]
                )

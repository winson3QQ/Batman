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
BATMAN_264 = "R1 R3 R4 R4b R5 R6 R7 R9 R10"  # BATMAN-264: which #264 items this overlay carries (payload-conform greps it)
# BATMAN-264-R6: client-socket keepalive (seconds / count / ms): a peer that vanished is gone in about 2 minutes
KEEPALIVE_IDLE = 45
KEEPALIVE_INTVL = 15
KEEPALIVE_CNT = 4
KEEPALIVE_USER_TIMEOUT_MS = 120000
DRAIN_MAX_S = 60
SUBSCRIBE_RETRY_S = 15  # BATMAN-264-R10: a queue held by another session (a stale one is reaped by R6 in ~2 min)  # BATMAN-264-R4b: a client that leaves while the broker is away: the child stays this long to deliver its cache
# BATMAN-264-R7: a new session is refused when the container has less than this much memory left. Measured on the
# node (2026-10-11, 512 MiB cgroup): upstream costs 39 MB per idle session (the child's Flask+Security build 28.6 MB
# plus the child's first gc pass copying 58.7 MB of the parent's heap); the kernel OOM-kills the whole container
# (PID 1 = every session) at about the 10th client. With the shared app and gc.freeze() below a session costs a
# few MB, and the reserve turns the remaining limit into a refused connection instead of a container kill.
SESSION_RESERVE_MB = int(os.environ.get("BATMAN_264_SESSION_RESERVE_MB", "40"))


# BATMAN-264-R10: the client's uid and callsign become queue names (declare/bind/consume) on the shared broker,
# unauthenticated on 8088. A callsign equal to a system queue would consume that queue (callsign "cot_parser"
# steals every CoT from storage, round-robin with cot_parser); "amq.*" is refused by the broker with a channel
# error; a name over 255 bytes raises inside pika. Refused names get no subscription (the CoT is still stored).
RESERVED_NAMES = frozenset({"cot_parser", "dms", "chatrooms", "missions", "groups", "firehose", "flask-socketio",
                            "meshtastic", "dmrcot"})


def _valid_name(name):
    if not isinstance(name, str) or not name or len(name.encode("utf-8", "replace")) > 255:
        return False
    low = name.lower()
    if low.startswith("amq.") or low in RESERVED_NAMES:
        return False
    return all(c.isprintable() for c in name)


def _cg_mem():
    """(used, max) bytes of this container's own cgroup; (None, None) when unreadable (then no cap). "Used" is
    the anonymous memory (memory.stat anon: what the kernel cannot reclaim), not memory.current, which also
    counts page cache and would refuse sessions after days of log writes (review B-6)."""
    try:
        cur = None
        with open("/sys/fs/cgroup/memory.stat") as f:
            for line in f:
                if line.startswith("anon "):
                    cur = int(line.split()[1])
                    break
        if cur is None:
            with open("/sys/fs/cgroup/memory.current") as f:
                cur = int(f.read())
        with open("/sys/fs/cgroup/memory.max") as f:
            mx = f.read().strip()
        return cur, (None if mx == "max" else int(mx))
    except (OSError, ValueError):
        return None, None


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
        self._drained = threading.Event()
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
        self._need_replay = False    # BATMAN-264-R4: re-run the recorded subscription on the next channel
        self._sub_ops = None
        self._chan_errors = []
        self._reconnect_n = 0
        self._reconnect_timer = None
        self._ioloop = None
        self._end_args = None        # BATMAN-264-R4b: (uid, body, binds) of a client that left while the broker was away
        self._subscribed = False     # BATMAN-264-R10: the per-EUD subscription is made once per session
        self._squat_logged = False
        self._sub_timer = None
        self._ret_n = 0              # returns of one burst keep their order at the cache head
        self.iothread = None
        if not self._session_allowed():  # BATMAN-264-R7: fail closed before anything is allocated or declared
            self.shutdown = True
            try:
                self.request.close()
            except OSError:
                pass
            return
        self._keepalive(self.request)  # BATMAN-264-R6: a vanished peer ends the session in about 2 min
        self.create_app()

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
                    blocked_connection_timeout=60,  # BATMAN-264-R9: a broker blocked for 60 s ends the connection
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

        if self.cached_messages or self._dropped:  # BATMAN-264-R9: never silent
            self.logger.error(f"session end: {len(self.cached_messages)} cached and {self._dropped} dropped cot never delivered")

        def _close_on_ioloop():
            for attr in ("_retry_timer", "_reconnect_timer"):  # BATMAN-264-R5/R4
                t = getattr(self, attr)
                if t is not None:
                    try:
                        self._ioloop.remove_timeout(t)
                    except Exception:
                        pass
                    setattr(self, attr, None)
            try:
                if self.rabbit_channel and self.rabbit_channel.is_open:
                    self._flush_cache()  # BATMAN-264-R4b: cached bodies leave before the disconnect; their acks precede CloseOk
                    self._end_session(uid, body, binds)  # BATMAN-264-R6: cancel, count peers, then disconnect/unbind
                elif (self.cached_messages or self._unacked) and not self._loop_dead:
                    # BATMAN-264-R4b: the broker is away while the client leaves: keep this child for a bounded
                    # time, let the reconnect flush the cache, then end the session (upstream lost all of it)
                    self._end_args = (uid, body, binds)
                    self._schedule_reconnect()
                else:
                    self._drained.set()
            except Exception as e:
                self.logger.error(f"close on ioloop failed: {e}")
                self._drained.set()

        pending = bool(self.cached_messages or self._unacked)
        self._drained.clear()  # set by every earlier channel/connection close: it must mean THIS close
        if self._sub_timer is not None:
            try:
                self._ioloop.remove_timeout(self._sub_timer)
            except Exception:
                pass
            self._sub_timer = None
        if threading.current_thread() is self.iothread:
            _close_on_ioloop()  # called from on_message: never wait for ourselves
        elif self._io(_close_on_ioloop):
            if not self._drained.wait(DRAIN_MAX_S if pending else 3.0) and pending:
                self.logger.error(f"session end: {len(self.cached_messages)} cached and {len(self._unacked)} unacked cot not delivered within {DRAIN_MAX_S} s")

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

    def _owned_by_user(self, uid, callsign):
        # BATMAN-264-R10: does an EUD row with this uid or callsign belong to an OTS user (an 8089 device)?
        # True / False, or None when the database did not answer (the caller retries later).
        try:
            with self.app.app_context():
                row = db.session.execute(
                    select(EUD.uid).filter((EUD.uid == uid) | (EUD.callsign == callsign)).filter(EUD.user_id.isnot(None))
                ).first()
            return row is not None
        except Exception as e:
            self.logger.error(f"ownership lookup failed ({e}); not subscribing yet, retried on the next report")
            return None

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
        self.rabbit_connection.channel(on_open_callback=self.on_channel_open)

    def on_channel_open(self, channel: Channel):
        self.logger.debug(f"Opening RabbitMQ channel for {self.callsign or self.client_address[0]}")
        self.rabbit_channel = channel
        self.rabbit_channel.add_on_close_callback(self.on_channel_close)
        self.rabbit_channel.add_on_return_callback(self._on_return)  # BATMAN-264-R5: unroutable -> cache
        self.rabbit_channel.confirm_delivery(self._on_confirm)      # BATMAN-264-R4b: at-least-once
        self._pub_seq = 0
        self._requeue_unacked()
        self._reconnect_n = 0
        if self._need_replay and self._sub_ops:  # BATMAN-264-R4: the subscription of the previous channel
            self._subscribed = False
            self._subscribe(self._sub_ops)  # clears _need_replay when the consumes are placed

        self.rabbit_channel.exchange_declare(
            "flask-socketio", durable=False, exchange_type="fanout"
        )

        if self._pending_ops:  # BATMAN-264: a subscription requested before the channel was open
            ops, self._pending_ops = self._pending_ops, None
            self._subscribe(ops)

        self._flush_cache()  # BATMAN-264-R9: cot_parser bodies cached while the channel was closed/blocked
        if self._end_args:   # BATMAN-264-R4b: the client already left; the cache is flushed, now end the session
            uid, body, binds = self._end_args
            self._end_args = None
            self._end_session(uid, body, binds)
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

    def on_channel_close(self, channel: Channel, error):
        self._drained.set()  # BATMAN-264: CloseOk received -> earlier frames were sent
        if self._closed and not self._end_args:
            if self.rabbit_connection and self.rabbit_connection.is_open:
                self.rabbit_connection.close()  # session end: upstream's order (channel, then connection, then loop)
            return
        # BATMAN-264-R4: upstream ended the session here (shutdown=True, connection.close()); a channel error
        # (a refused declare, a bad queue name on replay) now costs this channel only: unacked bodies go back
        # to the cache, the channel is reopened on the same connection and the subscription replayed. A
        # channel that keeps failing (3 closes within 60 s) ends the session loudly: the client reconnects and
        # starts clean, instead of looking connected while receiving nothing.
        self.rabbit_channel = None
        self._subscribed = False
        self._requeue_unacked()
        if not (self.rabbit_connection and self.rabbit_connection.is_open):
            return  # the connection is going too: on_close reconnects and replays
        self.logger.error(f"RabbitMQ channel closed for {self.callsign}: {error}; reopening")
        now = time.monotonic()
        self._chan_errors = [t for t in self._chan_errors if now - t < 60] + [now]
        if len(self._chan_errors) >= 3:
            self.logger.error(f"{self.callsign}: the channel keeps failing ({error}); ending the session")
            self._sub_ops = None
            self._end_args = None
            if not self._closed:
                self.close_connection()
            elif self.rabbit_connection and self.rabbit_connection.is_open:
                self.rabbit_connection.close()
            return
        self._need_replay = True
        if self.rabbit_connection and self.rabbit_connection.is_open:
            self.rabbit_connection.channel(on_open_callback=self.on_channel_open)
        # self.request.shutdown(socket.SHUT_RDWR)
        # self.sock.close()

    def on_close(self, connection, error):
        self.logger.info("Connection closed for {}: {}".format(self.client_address[0], error))
        self._drained.set()  # BATMAN-264
        if self._closed and not self._end_args:
            # Stop the ioloop using add_callback_threadsafe because ioloop.stop() isn't threadsafe
            connection.ioloop.add_callback_threadsafe(self._ioloop.stop)
            return
        # BATMAN-264-R4 (#264 mechanism B): the broker ended the connection (missed heartbeats, broker restart,
        # rabbitmqctl close_connection). Upstream let the session die with everything in flight. Keep the
        # session and the ioloop; unacked bodies go back to the cache; reconnect with backoff 1..30 s.
        self.rabbit_channel = None
        self._decl_channel = None
        self._blocked = False
        self._subscribed = False
        self._requeue_unacked()
        self._need_replay = True
        self._schedule_reconnect()

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
        if self._closed and not self._end_args:
            connection.ioloop.stop()
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

    def _subscribe(self, ops):
        # replay queue_declare / queue_bind / basic_consume recorded by parse_device_info; if the channel is
        # not open yet (a client often sends its first CoT before AMQP is up), do it in on_channel_open
        # instead of never (upstream skipped the subscription for good)
        # BATMAN-264-R10: once per session (upstream identifies a session once too: handle_cot runs
        # parse_device_info only while self.uid is unset), replayed on a new channel, and only when nobody else
        # consumes the EUD's queues: the broker's DeclareOk carries consumer_count; another consumer means
        # another session of the same uid/callsign (this device's stale session, gone within ~2 min by R6, or a
        # second device claiming the name). Then: no subscription now, one log line, a retry timer every
        # SUBSCRIBE_RETRY_S (a reconnecting phone is subscribed once its stale session is reaped).
        self._sub_ops = ops  # BATMAN-264-R4: replayed on the channel after a reconnect
        if self._subscribed and not self._need_replay:
            return
        if not (self.rabbit_channel and self.rabbit_channel.is_open):
            self._pending_ops = ops
            return
        ch = self.rabbit_channel
        declares = [op for op in ops if op[0] == "queue_declare"]
        rest = [op for op in ops if op[0] != "queue_declare"]
        replay = self._need_replay
        state = {"n": len(declares), "busy": None}

        def retry():
            self._sub_timer = None
            if not self._closed:
                self._subscribe(ops)

        def finish():
            if state["busy"] and not replay:
                if not self._squat_logged:
                    self._squat_logged = True
                    self.logger.error(
                        f"{self.client_address[0]}: queue {state['busy']} already has a consumer (another session "
                        f"of this uid/callsign); not subscribing now, retried every {SUBSCRIBE_RETRY_S} s")
                if self._sub_timer is None and not self._closed:
                    self._sub_timer = self._ioloop.call_later(SUBSCRIBE_RETRY_S, retry)
                return
            try:
                for name, a, k in rest:
                    getattr(ch, name)(*a, **k)
            except Exception as e:
                self.logger.error(f"subscription failed ({e}); the channel close path handles it")
                return
            self._subscribed = True
            self._need_replay = False
            self.logger.info(f"subscribed {self.uid}/{self.callsign} for {self.client_address[0]}"
                             f"{' (replay)' if replay else ''}{' (after waiting for another session)' if self._squat_logged else ''}")

        def declared(frame):
            m = getattr(frame, "method", None)
            if getattr(m, "consumer_count", 0) and state["busy"] is None:
                state["busy"] = getattr(m, "queue", "?")
            state["n"] -= 1
            if state["n"] == 0:
                finish()

        if not declares:
            finish()
            return
        for name, a, k in declares:
            ch.queue_declare(*a, callback=declared, **k)

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
        if self.rabbit_connection is not None and self.rabbit_connection.is_open:
            return
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

    def _end_session(self, uid, body, binds):
        # ioloop thread. cot_parser's send_disconnect_cot (cot_parser.py:944-1033) unbinds <uid> from EVERY group
        # and mission on a disconnect message, whoever else still holds that queue, and upstream's close also
        # unbound the dms/groups/missions bindings unconditionally: when a stale session of an EUD ended, the
        # EUD's live session (same uid, reconnected phone) lost all its bindings (measured: 10/10 -> 0/10).
        # So: cancel this session's consumers, ask the broker how many consumers the <uid> queue still has, and
        # publish the disconnect + unbind only when this was the last session of that EUD. The last session also
        # removes the EUD's queues when they are idle and empty (review F3: upstream left them behind for ever,
        # one orphan per EUD ever seen); a queue with messages stays (TTL 24 h) and is declared again next time.
        ch = self.rabbit_channel
        for tag in list(getattr(ch, "consumer_tags", []) or []):
            try:
                ch.basic_cancel(tag)
            except Exception as e:
                self.logger.error(f"basic_cancel failed: {e}")

        empty = []   # queues seen with no consumer and no message: safe to delete

        def finish(last):
            try:
                if last:
                    ch.basic_publish(
                        exchange="cot_parser",
                        body=body,
                        routing_key="cot_parser",
                        properties=pika.BasicProperties(expiration=self.app.config.get("OTS_RABBITMQ_TTL")),
                    )
                    self.unbind_rabbitmq_queues(uid, binds)
                    for q in empty:
                        ch.queue_delete(queue=q, if_unused=True, if_empty=True)
                else:
                    self.logger.info(f"another session of {uid} is live: no disconnect, bindings kept")
            finally:
                ch.close()  # on_channel_close (CloseOk) sets _drained

        if not uid or not self._subscribed:
            # never identified, a relay platform, a refused name, or not yet subscribed: upstream's path (the
            # disconnect message; cot_parser ignores a uid-less one), no queue check (a passive declare of a
            # queue this session never declared would be a 404) and no delete
            finish(True)
            return

        names = [q for q in (uid, self.callsign) if q]
        if len(names) == 2 and names[0] == names[1]:
            names = names[:1]

        state = {"i": 0}

        def declared(frame):
            m = getattr(frame, "method", None)
            if getattr(m, "consumer_count", 0):
                finish(False)
                return
            if not getattr(m, "message_count", 0):
                empty.append(names[state["i"]])
            state["i"] += 1
            if state["i"] < len(names):
                ch.queue_declare(queue=names[state["i"]], passive=True, callback=declared)
            else:
                finish(True)

        try:
            ch.queue_declare(queue=names[0], passive=True, callback=declared)
        except Exception as e:
            self.logger.error(f"passive declare of {uid} failed: {e}")
            finish(True)

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

        if event and not self.uid:
            self.parse_device_info(event)
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
                if not (_valid_name(self.uid) and _valid_name(self.callsign)):  # BATMAN-264-R10
                    self.logger.error(
                        f"refusing the subscription of {self.client_address[0]}: uid or callsign is not a usable "
                        f"queue name (empty, >255 bytes, amq.*, a system name or not printable); no EUD row, so "
                        f"cot_parser stores nothing from it")
                    return
                owned = self._owned_by_user(self.uid, self.callsign) if not self.is_ssl else False
                if owned is None:  # BATMAN-264-R10: database down: identify again on the next report
                    self.uid = None
                    return
                if owned:  # BATMAN-264-R10 (review F8/M7)
                    # an unauthenticated 8088 client naming an authenticated user's device: no subscription (it
                    # would receive that user's DMs and group traffic) and no EUD row update (it would detach the
                    # device from its user). Measured on the node: cot_parser then stores nothing from this
                    # session (no EUD row for the sender), so the user's track is not polluted either.
                    if not self._squat_logged:
                        self._squat_logged = True
                        self.logger.error(
                            f"refusing the subscription of {self.client_address[0]} on the plaintext listener: "
                            f"uid/callsign {self.uid}/{self.callsign} belong to an authenticated user's device")
                    return
                if (
                    platform != "OpenTAK ICU"
                    and platform != "Meshtastic"
                    and platform != "DMRCOT"
                ):

                    self.logger.debug(f"Declaring queue for {self.callsign} {self.uid}")
                    _ch.queue_declare(queue=self.callsign)
                    _ch.queue_declare(queue=self.uid)

                    with self.app.app_context():
                        if self.is_ssl:
                            group_memberships = db.session.execute(
                                db.session.query(GroupUser).filter_by(
                                    user_id=self.user.id, direction=Group.OUT
                                )
                            ).all()
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

                        if {
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

                        _ch.basic_consume(
                            queue=self.callsign, on_message_callback=self.on_message, auto_ack=True
                        )
                        _ch.basic_consume(
                            queue=self.uid, on_message_callback=self.on_message, auto_ack=True
                        )
                if _ch.ops:
                    self._io(self._subscribe, _ch.ops)

            if "phone" in contact.attrs and contact.attrs["phone"]:
                self.phone_number = contact.attrs["phone"]

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
                    eud.callsign = self.callsign
                if device:
                    eud.device = device

                eud.os = operating_system
                eud.platform = platform
                eud.version = version
                eud.phone_number = self.phone_number
                eud.last_event_time = datetime_from_iso8601_string(event.attrs["start"])
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
                    eud.team_role = bleach.clean(__group.attrs["role"])

                try:
                    db.session.add(eud)
                    db.session.commit()
                except sqlalchemy.exc.IntegrityError:
                    db.session.rollback()
                    db.session.execute(
                        update(EUD).where(EUD.uid == eud.uid).values(**eud.serialize())
                    )
                    db.session.commit()

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

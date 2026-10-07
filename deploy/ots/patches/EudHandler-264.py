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
        self.create_app()

        # RabbitMQ
        try:
            rabbit_credentials = pika.PlainCredentials(
                self.app.config.get("OTS_RABBITMQ_USERNAME"),
                self.app.config.get("OTS_RABBITMQ_PASSWORD"),
            )
            rabbit_host = self.app.config.get("OTS_RABBITMQ_SERVER_ADDRESS")
            self.rabbit_connection = pika.SelectConnection(
                pika.ConnectionParameters(host=rabbit_host, credentials=rabbit_credentials),
                self.on_connection_open,
                on_open_error_callback=self.on_open_error,  # BATMAN-264: upstream had none -> ioloop died
                on_close_callback=self.on_close,
            )
            self.rabbit_channel: Channel | None = None
            # Start the pika ioloop in a thread or else it blocks and we can't receive any CoT messages
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
            self.shutdown = True

            self.request.shutdown(SHUT_RDWR)
            self.request.close()

    def create_app(self):
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
        self.rabbit_connection.channel(on_open_callback=self.on_channel_open)

    def on_channel_open(self, channel: Channel):
        self.logger.debug(f"Opening RabbitMQ channel for {self.callsign or self.client_address[0]}")
        self.rabbit_channel = channel
        self.rabbit_channel.add_on_close_callback(self.on_channel_close)

        self.rabbit_channel.exchange_declare(
            "flask-socketio", durable=False, exchange_type="fanout"
        )

        if self._pending_ops:  # BATMAN-264: a subscription requested before the channel was open
            ops, self._pending_ops = self._pending_ops, None
            self._subscribe(ops)

        for message in self.cached_messages:
            self.publish_cot(message)

        self.cached_messages.clear()

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
            self.rabbit_channel.basic_publish(
                "flask-socketio",
                "",
                json.dumps(message),
                properties=pika.BasicProperties(expiration=self.app.config.get("OTS_RABBITMQ_TTL")),
            )

    def on_channel_close(self, channel: Channel, error):
        self.logger.error(f"RabbitMQ channel closed for {self.callsign}, shut it down")
        self._drained.set()  # BATMAN-264: CloseOk received -> earlier frames were sent
        if (
            self.rabbit_connection
            and not self.rabbit_connection.is_closing
            and not self.rabbit_connection.is_closed
        ):
            self.rabbit_connection.close()

        self.shutdown = True
        # self.request.shutdown(socket.SHUT_RDWR)
        # self.sock.close()

    def on_close(self, connection, error):
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

        def _both():
            # Route all CoTs to the firehose exchange for plugins and users that connect directly to RabbitMQ
            self._publish_on_ioloop("firehose", "", fh)
            # Route all cots to the cot_parser direct exchange to be processed by a pool of cot_parser processes
            self._publish_on_ioloop("cot_parser", "cot_parser", cp, event)

        if not self._io(_both):
            self._cache(event)

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

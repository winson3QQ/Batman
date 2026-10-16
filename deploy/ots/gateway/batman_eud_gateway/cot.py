"""CoT parsing and construction (M1 parse, M5 bodies, M8 presence event).

Parsing uses bs4 with the lxml "xml" parser exactly as upstream cot_parser does, so what the gateway
accepts is what cot_parser will accept. A message with a DOCTYPE yields no <event> (probed on the
image) and is reported as malformed. Only the attributes the gateway needs are extracted; the raw
bytes are what gets published (never a re-serialisation).
"""
from __future__ import annotations

import dataclasses
import datetime as _dt
import json
import uuid

from bs4 import BeautifulSoup

PING_TYPE = "t-x-c-t"
PONG_TYPE = "t-x-c-t-r"
PRESENCE_TYPE = "t-x-d-d"
RELAY_PLATFORMS = frozenset({"OpenTAK ICU", "Meshtastic", "DMRCOT"})


class Malformed(Exception):
    pass


@dataclasses.dataclass
class Event:
    raw: bytes
    uid: str
    type: str
    start: str | None
    callsign: str | None          # <contact callsign>
    phone: str | None             # <contact phone>
    has_contact: bool
    has_takv: bool
    device: str | None
    os: str | None
    platform: str | None
    version: str | None
    group_name: str | None        # <__group name>
    group_role: str | None        # <__group role>

    @property
    def is_ping(self) -> bool:
        return self.type == PING_TYPE

    @property
    def identifies(self) -> bool:
        """Upstream parse_device_info: an EUD is identified by a CoT with a <contact> (or <takv>) element
        whose uid does not end in 'ping'."""
        return self.has_contact and bool(self.uid) and not self.uid.endswith("ping")


def parse_event(raw: bytes) -> Event:
    try:
        soup = BeautifulSoup(raw, "xml")
    except Exception as e:  # pragma: no cover - bs4 recovers almost everything
        raise Malformed(str(e))
    ev = soup.find("event")
    if ev is None:
        raise Malformed("no <event>")
    a = ev.attrs
    uid = a.get("uid", "")
    typ = a.get("type", "")
    if not uid or not typ:
        raise Malformed("event without uid/type")
    contact = ev.find("contact")
    takv = ev.find("takv")
    grp = ev.find("__group")
    return Event(
        raw=raw, uid=uid, type=typ, start=a.get("start"),
        callsign=(contact.attrs.get("callsign") if contact is not None else None),
        phone=(contact.attrs.get("phone") if contact is not None else None),
        has_contact=contact is not None, has_takv=takv is not None,
        device=(takv.attrs.get("device") if takv is not None else None),
        os=(takv.attrs.get("os") if takv is not None else None),
        platform=(takv.attrs.get("platform") if takv is not None else None),
        version=(takv.attrs.get("version") if takv is not None else None),
        group_name=(grp.attrs.get("name") if grp is not None else None),
        group_role=(grp.attrs.get("role") if grp is not None else None),
    )


def parse_auth(raw: bytes) -> dict | None:
    """<auth><cot username= password= uid= callsign=/></auth> -> attrs, or None if malformed.
    The gateway only answers it (M2.6); LDAP/password auth is not used on 8089 (the cert is the identity)."""
    soup = BeautifulSoup(raw, "xml")
    cot = soup.find("cot")
    return dict(cot.attrs) if cot is not None else None


# -- construction ------------------------------------------------------------------------------
def _iso(t: _dt.datetime) -> str:
    return t.strftime("%Y-%m-%dT%H:%M:%S.") + "%03dZ" % (t.microsecond // 1000)


def pong() -> bytes:
    now = _dt.datetime.now(_dt.timezone.utc)
    return (f'<event version="2.0" uid="takPong" type="{PONG_TYPE}" how="h-g-i-g-o" time="{_iso(now)}" '
            f'start="{_iso(now)}" stale="{_iso(now + _dt.timedelta(seconds=20))}">'
            '<point lat="0" lon="0" hae="0" ce="9999999" le="9999999"/><detail/></event>').encode()


def presence_offline(device_uid: str, device_type: str = "a-f-G-U-C") -> bytes:
    """M8: the t-x-d-d event EXACTLY as upstream cot_parser builds it (cot_parser.py:945-975): every
    attribute insert_cot reads is present (how/type/start/stale/time/uid), the device in <link>."""
    now = _dt.datetime.now(_dt.timezone.utc)
    return (f'<event version="2.0" uid="{uuid.uuid4()}" type="{PRESENCE_TYPE}" how="h-g-i-g-o" '
            f'time="{_iso(now)}" start="{_iso(now)}" stale="{_iso(now + _dt.timedelta(seconds=10))}">'
            '<point ce="9999999" le="9999999" hae="0" lat="0" lon="0"/>'
            f'<detail><link relation="p-p" uid="{_xml_attr(device_uid)}" type="{_xml_attr(device_type)}"/></detail>'
            '</event>').encode()


def _xml_attr(s: str) -> str:
    return s.replace("&", "&amp;").replace('"', "&quot;").replace("<", "&lt;").replace(">", "&gt;")


def uplink_body(uid: str | None, raw: bytes, user_id: int | None) -> bytes:
    """The cot_parser contract: {"uid": <device uid or null>, "cot": "<event…>", "user_id": <int|null>}."""
    return json.dumps({"uid": uid, "cot": raw.decode("utf-8", "replace"), "user_id": user_id}).encode()


def firehose_body(uid: str | None, raw: bytes) -> bytes:
    return json.dumps({"uid": uid, "cot": raw.decode("utf-8", "replace")}).encode()


def socketio_eud_message(eud_json: dict) -> bytes:
    """The flask-socketio fanout message the web map expects (EudHandler.py:291-305)."""
    return json.dumps({
        "method": "emit", "event": "eud", "data": eud_json, "namespace": "/socket.io",
        "room": None, "skip_sid": None, "callback": None, "binary": False, "host_id": uuid.uuid4().hex,
    }).encode()


def downlink_payload(body: bytes) -> bytes:
    """Broker -> phone: upstream publishes either {"uid","cot"} JSON or a raw CoT string (route_cot).
    Return the CoT bytes to write to the socket, or raise Malformed."""
    s = body.lstrip()
    if s.startswith(b"{"):
        try:
            d = json.loads(s)
            cot = d.get("cot")
        except Exception:
            raise Malformed("downlink json")
        if not isinstance(cot, str) or not cot:
            raise Malformed("downlink json without cot")
        return cot.encode()
    if s.startswith(b"<"):
        return bytes(s)
    raise Malformed("downlink body")

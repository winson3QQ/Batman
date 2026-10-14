import json

import pytest

from batman_eud_gateway import cot

SA = (b'<event version="2.0" uid="ANDROID-1" type="a-f-G-U-C" how="h-e" time="2026-10-14T01:00:00.000Z" '
      b'start="2026-10-14T01:00:00.000Z" stale="2026-10-14T01:10:00.000Z"><point lat="25.03" lon="121.56" hae="10" '
      b'ce="9999999" le="9999999"/><detail><takv device="Pixel" os="34" platform="ATAK-CIV" version="5.1"/>'
      b'<contact callsign="ALPHA" phone="555-123-4567"/><__group name="Cyan" role="Team Member"/></detail></event>')


def test_parse_sa():
    e = cot.parse_event(SA)
    assert e.uid == "ANDROID-1" and e.callsign == "ALPHA" and e.phone == "555-123-4567"
    assert e.platform == "ATAK-CIV" and e.device == "Pixel" and e.group_name == "Cyan" and e.group_role == "Team Member"
    assert e.identifies and not e.is_ping and e.start == "2026-10-14T01:00:00.000Z"


def test_ping_does_not_identify():
    e = cot.parse_event(b'<event version="2.0" uid="ANDROID-1-ping" type="t-x-c-t" time="x" start="x" stale="x"/>')
    assert e.is_ping and not e.identifies


def test_contactless_does_not_identify():
    e = cot.parse_event(b'<event uid="u" type="b-m-p-s-m"><point/><detail/></event>')
    assert not e.identifies


def test_malformed_and_doctype():
    with pytest.raises(cot.Malformed):
        cot.parse_event(b"<event>")          # no uid/type
    with pytest.raises(cot.Malformed):
        cot.parse_event(b"not xml at all")
    bomb = (b'<?xml version="1.0"?><!DOCTYPE e [<!ENTITY a "aaaaaaaaaa"><!ENTITY b "&a;&a;&a;&a;&a;&a;&a;&a;&a;&a;">]>'
            b'<event uid="&b;" type="a-f"/>')
    with pytest.raises(cot.Malformed):
        cot.parse_event(bomb)


def test_presence_event_has_every_attribute_insert_cot_reads():
    raw = cot.presence_offline('DEV"1')
    e = cot.parse_event(raw)
    assert e.type == "t-x-d-d"
    for attr in (b'how="h-g-i-g-o"', b"start=", b"stale=", b"time=", b'uid="'):
        assert attr in raw
    assert b'<link relation="p-p" uid="DEV&quot;1" type="a-f-G-U-C"/>' in raw
    assert b'lat="0" lon="0"' in raw


def test_bodies():
    b = json.loads(cot.uplink_body("u", SA, 7))
    assert b == {"uid": "u", "cot": SA.decode(), "user_id": 7}
    f = json.loads(cot.firehose_body(None, SA))
    assert f == {"uid": None, "cot": SA.decode()}
    m = json.loads(cot.socketio_eud_message({"uid": "u"}))
    assert m["event"] == "eud" and m["data"] == {"uid": "u"} and m["namespace"] == "/socket.io"


def test_downlink_payload_forms():
    assert cot.downlink_payload(json.dumps({"uid": "u", "cot": "<event/>"}).encode()) == b"<event/>"
    assert cot.downlink_payload(b"  <event uid='x'/>") == b"<event uid='x'/>"
    for bad in (b"{}", b'{"cot": 5}', b"zzz"):
        with pytest.raises(cot.Malformed):
            cot.downlink_payload(bad)


def test_pong_parses():
    e = cot.parse_event(cot.pong())
    assert e.type == "t-x-c-t-r"

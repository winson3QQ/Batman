import pytest

from batman_eud_gateway.framing import CarryOverflow, Framer


def ev(uid="u1", body=b""):
    return (b'<event version="2.0" uid="' + uid.encode() + b'" type="a-f-G-U-C"><point lat="1" lon="2"/>'
            b"<detail>" + body + b"</detail></event>")


def kinds(frames):
    return [f.kind for f in frames]


def test_complete_and_split_messages():
    f = Framer(65536, 1 << 20)
    a, b = ev("a"), ev("b")
    out = f.feed(a + b[:10])
    assert kinds(out) == ["event"] and out[0].data == a
    out = f.feed(b[10:])
    assert kinds(out) == ["event"] and out[0].data == b
    assert f.buf == b""


def test_prolog_and_whitespace_skipped():
    f = Framer(65536, 1 << 20)
    out = f.feed(b'<?xml version="1.0"?>\n  ' + ev("a") + b"\r\n")
    assert kinds(out) == ["event"]


def test_self_closing_ping():
    f = Framer(65536, 1 << 20)
    out = f.feed(b'<event uid="p-ping" type="t-x-c-t"/>' + ev("a"))
    assert kinds(out) == ["event", "event"]
    assert out[0].data.endswith(b"/>")


def test_auth_element():
    f = Framer(65536, 1 << 20)
    out = f.feed(b'<auth><cot username="u" password="p" uid="x"/></auth>' + ev("a"))
    assert kinds(out) == ["auth", "event"]


def test_oversize_is_discarded_and_stream_resyncs():
    f = Framer(1000, 1 << 20)
    big = ev("big", b"x" * 5000)
    out = []
    # feed in chunks so the oversize path crosses boundaries
    for i in range(0, len(big), 700):
        out += f.feed(big[i:i + 700])
    out += f.feed(ev("after"))
    assert kinds(out) == ["oversize", "event"]
    assert out[0].size == len(big)
    assert out[1].data == ev("after")
    assert f.skipping == 0 and f.buf == b""


def test_oversize_complete_in_one_feed():
    f = Framer(1000, 1 << 20)
    big = ev("big", b"x" * 5000)
    out = f.feed(big + ev("after"))
    assert kinds(out) == ["oversize", "event"]


def test_carry_overflow_without_closing_tag():
    f = Framer(1 << 20, 2000)   # carry bound below the event bound: a never-closing element must close
    with pytest.raises(CarryOverflow):
        f.feed(b"<event " + b"a" * 3000)


def test_junk_between_messages_dropped():
    f = Framer(65536, 1 << 20)
    out = f.feed(b"garbage<foo/>" + ev("a"))
    assert "event" in kinds(out) and out[-1].data == ev("a")


def test_doctype_is_not_an_event_frame():
    # a DOCTYPE entity bomb: the framer only sees "<!DOCTYPE" junk then the event; the parser layer (bs4)
    # yields no event for it (probed on the image), so it is dropped there as malformed.
    f = Framer(65536, 1 << 20)
    out = f.feed(b'<!DOCTYPE e [<!ENTITY a "aaaa">]>' + ev("a"))
    assert kinds(out)[-1] == "event"

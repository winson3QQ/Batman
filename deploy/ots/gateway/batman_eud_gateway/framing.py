"""M1 — framing of the TAK stream: bytes -> complete <event>…</event> / <auth>…</auth> messages.

Rules (design M1, R1 of #264):
- raw bytes are kept until a closing tag; only complete messages are decoded; the remainder carries over;
- a message over `max_event_bytes` is DISCARDED to its closing tag (the session goes on); the discard is
  counted and reported to the caller once per message;
- the carry-over without a closing tag is bounded by `max_carry_bytes`: over it the caller must close
  the connection (we raise CarryOverflow);
- the `<?xml …?>` prolog is skipped; anything that is not an event or auth element is reported as junk
  (dropped, counted).

The parser never builds a DOM: it scans for start/end tags with bytes.find, so a hostile client's
cost is linear in the bytes it sends (bounded by the uplink bucket, M1).
"""
from __future__ import annotations

import dataclasses

_EVENT_END = b"</event>"
_AUTH_END = b"</auth>"


class CarryOverflow(Exception):
    """The carry-over exceeded max_carry_bytes: the connection must be closed."""


@dataclasses.dataclass
class Frame:
    kind: str          # "event" | "auth" | "oversize" | "junk"
    data: bytes        # the complete element for event/auth; b"" for oversize (size in `size`)
    size: int = 0      # bytes consumed by this frame


class Framer:
    def __init__(self, max_event_bytes: int, max_carry_bytes: int):
        self.max_event = max_event_bytes
        self.max_carry = max_carry_bytes
        self.buf = bytearray()
        self.skipping = 0            # bytes already dropped of the oversize element being skipped
        self._skip_end: bytes | None = None   # the end tag we are scanning for while skipping

    def feed(self, data: bytes) -> list[Frame]:
        """Append bytes and return every complete frame now available."""
        self.buf += data
        out: list[Frame] = []
        while True:
            f = self._next()
            if f is None:
                break
            out.append(f)
        if len(self.buf) > self.max_carry:
            raise CarryOverflow(len(self.buf))
        return out

    # -- internals -----------------------------------------------------------------------------
    def _next(self) -> Frame | None:
        b = self.buf
        if self._skip_end is not None:
            return self._oversize_scan(self._skip_end)
        # skip leading whitespace / prolog / stray text up to the first '<'
        lt = b.find(b"<")
        if lt < 0:
            if len(b) > self.max_event:
                n = len(b); del b[:]; return Frame("junk", b"", n)
            return None
        if lt > 0:
            del b[:lt]
        if b.startswith(b"<?xml"):
            end = b.find(b"?>")
            if end < 0:
                return None
            del b[: end + 2]
            return self._next()
        if b.startswith(b"<event"):
            return self._element(b"<event", _EVENT_END, "event")
        if b.startswith(b"<auth"):
            return self._element(b"<auth", _AUTH_END, "auth")
        # some other element or garbage: drop up to the next '<' (or everything if none)
        nxt = b.find(b"<", 1)
        if nxt < 0:
            if len(b) > self.max_event:
                n = len(b); del b[:]; return Frame("junk", b"", n)
            return None
        del b[:nxt]
        return Frame("junk", b"", nxt)

    def _element(self, start: bytes, end: bytes, kind: str) -> Frame | None:
        b = self.buf
        # self-closing <event .../> (a ping can be one)
        gt = b.find(b">")
        if gt < 0:
            if len(b) > self.max_event:
                return self._oversize_scan(end)
            return None
        if b[gt - 1:gt] == b"/":
            n = gt + 1
            data = bytes(b[:n]); del b[:n]
            if n > self.max_event:
                return Frame("oversize", b"", n)
            return Frame(kind, data, n)
        e = b.find(end)
        if e < 0:
            if len(b) > self.max_event:
                return self._oversize_scan(end)
            return None
        n = e + len(end)
        data = bytes(b[:n]); del b[:n]
        if n > self.max_event:
            return Frame("oversize", b"", n)
        return Frame(kind, data, n)

    def _oversize_scan(self, end: bytes) -> Frame | None:
        """The element is already over the bound with no end yet: drop what we have, keep dropping
        until the end tag arrives (so the stream re-synchronises), and report one oversize frame."""
        b = self.buf
        self._skip_end = end
        e = b.find(end)
        if e >= 0:
            n = e + len(end) + self.skipping
            del b[: e + len(end)]
            self.skipping = 0
            self._skip_end = None
            return Frame("oversize", b"", n)
        # keep only a tail long enough to detect the end tag across a boundary
        keep = len(end) - 1
        dropped = max(0, len(b) - keep)
        if dropped:
            del b[:dropped]
            self.skipping += dropped
        return None

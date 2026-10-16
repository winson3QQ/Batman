"""Token buckets (M1 uplink rate, M2.5 new-device rate). Monotonic-clock based; no wall clock."""
from __future__ import annotations

import time


class TokenBucket:
    """Classic token bucket: `rate` tokens per second, up to `burst` tokens stored."""

    def __init__(self, rate: float, burst: float, now: float | None = None):
        self.rate = float(rate)
        self.burst = float(burst)
        self.tokens = float(burst)
        self.t = time.monotonic() if now is None else now

    def _refill(self, now: float) -> None:
        if now > self.t:
            self.tokens = min(self.burst, self.tokens + (now - self.t) * self.rate)
            self.t = now

    def take(self, n: float = 1.0, now: float | None = None) -> bool:
        """Consume n tokens if available; True on success."""
        now = time.monotonic() if now is None else now
        self._refill(now)
        if self.tokens >= n:
            self.tokens -= n
            return True
        return False

    def charge(self, n: float, now: float | None = None) -> float:
        """Consume n tokens unconditionally (may go negative) and return the seconds until the bucket is
        non-negative again (0.0 when it is). Used for uplink back-pressure: the bytes were already read, so
        they are charged and the reader pauses for the deficit."""
        now = time.monotonic() if now is None else now
        self._refill(now)
        self.tokens -= n
        if self.tokens >= 0:
            return 0.0
        return (-self.tokens) / self.rate if self.rate > 0 else float("inf")

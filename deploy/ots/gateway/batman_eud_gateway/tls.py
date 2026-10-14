"""M14 — the 8089 TLS context: CERT_REQUIRED against the OTS CA, the server cert, and the CRL honoured
only while it is valid by the NODE clock (lastUpdate <= now AND nextUpdate - now >= 30 days; A2-4/B2-1):
a CRL from the future or an expired one would fail EVERY handshake, so it is ignored (logged, counted)
rather than taking the server down. The context is rebuilt when any file's mtime changes (cert rotation
without restart) and re-evaluated daily / on a clock jump.
"""
from __future__ import annotations

import datetime as _dt
import logging
import os
import re
import ssl
import subprocess

log = logging.getLogger("gateway.tls")
CRL_MIN_REMAINING = _dt.timedelta(days=30)


def crl_validity(path: str) -> tuple[_dt.datetime, _dt.datetime] | None:
    """(lastUpdate, nextUpdate) of a PEM CRL, via the image's openssl (no cryptography dependency on the
    hot path; probed on 04: /usr/bin/openssl present). None if unreadable/unparseable."""
    try:
        out = subprocess.run(["openssl", "crl", "-noout", "-lastupdate", "-nextupdate", "-in", path],
                             capture_output=True, text=True, timeout=5)
    except Exception as e:
        log.warning("CRL %s: openssl failed: %s", path, e)
        return None
    if out.returncode != 0:
        return None
    m1 = re.search(r"lastUpdate=(.+)", out.stdout)
    m2 = re.search(r"nextUpdate=(.+)", out.stdout)
    if not (m1 and m2):
        return None
    try:
        fmt = "%b %d %H:%M:%S %Y %Z"
        return (_dt.datetime.strptime(m1.group(1).strip(), fmt).replace(tzinfo=_dt.timezone.utc),
                _dt.datetime.strptime(m2.group(1).strip(), fmt).replace(tzinfo=_dt.timezone.utc))
    except ValueError:
        return None


def crl_usable(path: str, now: _dt.datetime | None = None) -> tuple[bool, str]:
    if not os.path.isfile(path):
        return False, "absent"
    v = crl_validity(path)
    if v is None:
        return False, "unparseable"
    last, nxt = v
    now = now or _dt.datetime.now(_dt.timezone.utc)
    if last > now:
        return False, f"not yet valid by the node clock (lastUpdate {last:%Y-%m-%d}, now {now:%Y-%m-%d})"
    if nxt - now < CRL_MIN_REMAINING:
        return False, f"expires too soon (nextUpdate {nxt:%Y-%m-%d}, now {now:%Y-%m-%d})"
    return True, f"valid {last:%Y-%m-%d} .. {nxt:%Y-%m-%d}"


class TlsContextHolder:
    def __init__(self, ca_pem: str, server_pem: str, server_key: str, crl: str):
        self.files = {"ca": ca_pem, "cert": server_pem, "key": server_key, "crl": crl}
        self.ctx: ssl.SSLContext | None = None
        self.mtimes: dict[str, float] = {}
        self.crl_honoured = False
        self.crl_reason = ""
        self.built_at: float = 0.0

    def files_present(self) -> bool:
        return all(os.path.isfile(self.files[k]) for k in ("ca", "cert", "key"))

    def _stat(self) -> dict[str, float]:
        out = {}
        for k, p in self.files.items():
            try:
                out[k] = os.stat(p).st_mtime
            except OSError:
                out[k] = -1.0
        return out

    def changed(self) -> bool:
        return self._stat() != self.mtimes

    def build(self, now: _dt.datetime | None = None) -> ssl.SSLContext:
        ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        ctx.verify_mode = ssl.CERT_REQUIRED
        ctx.load_cert_chain(self.files["cert"], self.files["key"])
        ctx.load_verify_locations(cafile=self.files["ca"])
        ok, reason = crl_usable(self.files["crl"], now)
        if ok:
            try:
                ctx.load_verify_locations(cafile=self.files["crl"])
                ctx.verify_flags |= ssl.VERIFY_CRL_CHECK_LEAF
                self.crl_honoured = True
            except ssl.SSLError as e:
                ok, reason = False, f"load failed: {e}"
        if not ok:
            self.crl_honoured = False
            log.warning("CRL not honoured: %s", reason)
        self.crl_reason = reason
        self.ctx = ctx
        self.mtimes = self._stat()
        self.built_at = _dt.datetime.now(_dt.timezone.utc).timestamp()
        log.info("TLS context built (CRL %s: %s)", "honoured" if self.crl_honoured else "ignored", reason)
        return ctx

    def refresh_if_needed(self, daily: bool = True) -> bool:
        """Rebuild on any file change, or once a day (the CRL window moves with the clock)."""
        now = _dt.datetime.now(_dt.timezone.utc).timestamp()
        if self.ctx is None or self.changed() or (daily and now - self.built_at > 86400) or now < self.built_at - 60:
            try:
                self.build()
                return True
            except Exception as e:
                log.error("TLS context rebuild failed, keeping the old one: %s", e)
        return False

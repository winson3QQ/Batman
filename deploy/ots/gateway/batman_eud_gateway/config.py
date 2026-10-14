"""M16 — configuration from the container environment (profile-owned), validated at start.

A malformed value is the ONLY reason the gateway exits 2 (design §1): everything else (DB late, schema
absent, TLS files missing, broker down) is waited for or retried. Defaults are the design's figures.
"""
from __future__ import annotations

import dataclasses
import os
import re

SYSTEM_NAMES = frozenset({
    "cot_parser", "dms", "chatrooms", "missions", "groups", "firehose", "flask-socketio",
    "meshtastic", "dmrcot",
})


class ConfigError(Exception):
    """A malformed configuration value — the caller exits 2."""


def name_ok(name: str) -> bool:
    """M4 name guard: a client-supplied uid/callsign may become a broker name only if it passes this.

    Empty, over 255 bytes of UTF-8, an `amq.` prefix (any case), a system queue/exchange name (exact,
    case-sensitive like queue names) or any non-printable character -> False.
    """
    if not name:
        return False
    if len(name.encode("utf-8", "surrogateescape")) > 255:
        return False
    if name.lower().startswith("amq."):
        return False
    if name in SYSTEM_NAMES:
        return False
    return all(ch.isprintable() for ch in name)


@dataclasses.dataclass(frozen=True)
class Settings:
    max_devices: int = 64
    max_devices_per_user: int = 4
    new_devices_burst: int = 4
    new_devices_per_h: int = 10
    max_conns_per_device: int = 3
    max_pending: int = 1024
    max_pending_per_user: int = 12
    reserve_mb: int = 64
    ident_max_s: int = 60
    ident_hard_s: int = 120
    supersede_quiet_s: int = 20
    supersede_max_s: int = 120
    max_event_bytes: int = 65536
    max_carry_bytes: int = 1048576
    uplink_bytes_per_s: int = 32768
    uplink_msgs_per_s: int = 20
    uplink_global_bytes_per_s: int = 262144
    cache_mb: int = 2
    sendq_mb: int = 1
    amqp_max_down_s: int = 300
    allowlist_8088: tuple[str, ...] = ()
    # fixed (not profile-owned)
    tcp_port: int = 8088
    tls_port: int = 8089
    health_port: int = 8090
    handshake_s: float = 10.0
    reconcile_s: int = 30
    snapshot_s: int = 10
    ots_dir: str = "/app/ots"
    snapshot_path: str = "/tmp/gateway/sessions.json"
    log_path: str = "/app/ots/logs/eud_gateway.log"

    @property
    def tcp_enabled(self) -> bool:
        return bool(self.allowlist_8088)


_INT_FIELDS = {
    "GATEWAY_MAX_DEVICES": "max_devices",
    "GATEWAY_MAX_DEVICES_PER_USER": "max_devices_per_user",
    "GATEWAY_NEW_DEVICES_BURST": "new_devices_burst",
    "GATEWAY_NEW_DEVICES_PER_H": "new_devices_per_h",
    "GATEWAY_MAX_CONNS_PER_DEVICE": "max_conns_per_device",
    "GATEWAY_MAX_PENDING": "max_pending",
    "GATEWAY_MAX_PENDING_PER_USER": "max_pending_per_user",
    "GATEWAY_RESERVE_MB": "reserve_mb",
    "GATEWAY_IDENT_MAX_S": "ident_max_s",
    "GATEWAY_IDENT_HARD_S": "ident_hard_s",
    "GATEWAY_SUPERSEDE_QUIET_S": "supersede_quiet_s",
    "GATEWAY_SUPERSEDE_MAX_S": "supersede_max_s",
    "GATEWAY_MAX_EVENT_BYTES": "max_event_bytes",
    "GATEWAY_MAX_CARRY_BYTES": "max_carry_bytes",
    "GATEWAY_UPLINK_BYTES_PER_S": "uplink_bytes_per_s",
    "GATEWAY_UPLINK_MSGS_PER_S": "uplink_msgs_per_s",
    "GATEWAY_UPLINK_GLOBAL_BYTES_PER_S": "uplink_global_bytes_per_s",
    "GATEWAY_CACHE_MB": "cache_mb",
    "GATEWAY_SENDQ_MB": "sendq_mb",
    "GATEWAY_AMQP_MAX_DOWN_S": "amqp_max_down_s",
}

_INT_RE = re.compile(r"^[0-9]{1,9}$")


def load(env: dict[str, str] | None = None) -> Settings:
    """Build Settings from the environment; raise ConfigError on any malformed value (fail-closed)."""
    env = os.environ if env is None else env
    kw: dict = {}
    for var, field in _INT_FIELDS.items():
        raw = env.get(var)
        if raw is None or raw == "":
            continue
        raw = raw.strip()
        if not _INT_RE.match(raw):
            raise ConfigError(f"{var}={raw!r} is not a non-negative integer")
        kw[field] = int(raw)
    raw_al = env.get("GATEWAY_8088_ALLOWLIST", "")
    names = tuple(n.strip() for n in raw_al.split(",") if n.strip())
    for n in names:
        if not name_ok(n):
            raise ConfigError(f"GATEWAY_8088_ALLOWLIST entry {n!r} fails the name guard")
    if len(set(names)) != len(names):
        raise ConfigError("GATEWAY_8088_ALLOWLIST has a duplicate uid")
    kw["allowlist_8088"] = names
    s = Settings(**kw)
    # sanity relations the design states
    if s.max_conns_per_device < 1 or s.max_devices < 1 or s.max_pending < 1:
        raise ConfigError("caps must be >= 1")
    if s.max_event_bytes > s.max_carry_bytes:
        raise ConfigError("GATEWAY_MAX_EVENT_BYTES must not exceed GATEWAY_MAX_CARRY_BYTES")
    if s.supersede_quiet_s > s.supersede_max_s:
        raise ConfigError("GATEWAY_SUPERSEDE_QUIET_S must not exceed GATEWAY_SUPERSEDE_MAX_S")
    return s

"""The OTS config.yml is the source of the DB URI, broker credentials, TTL and the CA folder (design §1:
the same source cot_parser's create_app() reads). Read once at start; secrets never logged."""
from __future__ import annotations

import dataclasses
import os

import yaml


@dataclasses.dataclass(frozen=True)
class OtsConfig:
    db_uri: str
    rabbit_host: str
    rabbit_user: str
    rabbit_password: str
    rabbit_ttl_ms: str
    ca_folder: str
    node_id: str

    @property
    def ca_pem(self) -> str:
        return os.path.join(self.ca_folder, "ca.pem")

    @property
    def ca_crl(self) -> str:
        return os.path.join(self.ca_folder, "ca.crl")

    @property
    def server_pem(self) -> str:
        return os.path.join(self.ca_folder, "certs", "opentakserver", "opentakserver.pem")

    @property
    def server_key(self) -> str:
        return os.path.join(self.ca_folder, "certs", "opentakserver", "opentakserver.nopass.key")

    def redacted(self) -> dict:
        d = dataclasses.asdict(self)
        d["rabbit_password"] = "<redacted>"
        d["db_uri"] = _redact_uri(self.db_uri)
        return d


def _redact_uri(uri: str) -> str:
    if "@" in uri and "://" in uri:
        head, tail = uri.split("://", 1)
        creds, rest = tail.split("@", 1)
        user = creds.split(":", 1)[0]
        return f"{head}://{user}:<redacted>@{rest}"
    return uri


def load(path: str = "/app/ots/config.yml", env: dict[str, str] | None = None) -> OtsConfig:
    """config.yml values, overridden by the same-named container env (the manifest sets
    SQLALCHEMY_DATABASE_URI and OTS_RABBITMQ_SERVER_ADDRESS, as it does for the OTS containers)."""
    env = os.environ if env is None else env
    with open(path, "r", encoding="utf-8") as f:
        cfg = yaml.safe_load(f) or {}

    def get(key: str, default=None):
        v = env.get(key)
        if v is not None and v != "":
            return v
        return cfg.get(key, default)

    return OtsConfig(
        db_uri=str(get("SQLALCHEMY_DATABASE_URI", "")),
        rabbit_host=str(get("OTS_RABBITMQ_SERVER_ADDRESS", "rabbitmq")),
        rabbit_user=str(get("OTS_RABBITMQ_USERNAME", "guest")),
        rabbit_password=str(get("OTS_RABBITMQ_PASSWORD", "guest")),
        rabbit_ttl_ms=str(get("OTS_RABBITMQ_TTL", "86400000")),
        ca_folder=str(get("OTS_CA_FOLDER", "/app/ots/ca")),
        node_id=str(get("OTS_NODE_ID", "")),
    )

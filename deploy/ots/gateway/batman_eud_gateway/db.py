"""Database access (M4 ownership, M5 store-before-route rows, M8 presence, M9 needed bindings,
M10 migration + scheduler watch). SQLAlchemy Core with explicit SQL against the OTS schema — no ORM
models, so the gateway needs no Flask app (the models are not importable standalone, A2-8); the
column names come from the live catalog (design §5). Every call here is BLOCKING and is run by the
gateway in its executor (4 threads) with a timeout; nothing here touches asyncio.

sqlite is supported for the offline tests (same SQL, minus the Postgres-only DDL); the dialect is
checked where it matters.
"""
from __future__ import annotations

import datetime as _dt
import logging
import re

import sqlalchemy as sa
from sqlalchemy import text

log = logging.getLogger("gateway.db")

SCHEMA_TABLES = ("euds", "cot", "points", "geochat", "apscheduler_jobs", "user", "groups",
                 "groups_users", "mission_roles")
RECORD_FKS = (  # (table, constraint name, column) — names from the 04 catalog (reviewers A2/B2)
    ("cot", "cot_eud", "sender_uid"),
    ("points", "point_eud", "device_uid"),
    ("geochat", "geochat_eud", "sender_uid"),
)
RETENTION_JOBS = ("delete_old_data", "purge_data")


def _cut(s: str | None, n: int = 255) -> str | None:
    if s is None:
        return None
    s = str(s)
    return s if len(s) <= n else s[:n]


def _as_dt(v) -> _dt.datetime | None:
    """text() queries give sqlite timestamps back as strings; Postgres gives datetimes."""
    if v is None or isinstance(v, _dt.datetime):
        return v
    try:
        return _dt.datetime.fromisoformat(str(v))
    except ValueError:
        return None


def phone_digits(phone: str | None) -> int | None:
    """euds.phone_number is BigInteger: keep the digits only (a '555-123-4567' is refused by postgres,
    #264 R14); nothing usable -> NULL."""
    if not phone:
        return None
    d = re.sub(r"\D", "", str(phone))
    if not d or len(d) > 18:
        return None
    return int(d)


class Database:
    def __init__(self, url: str, pool_size: int = 4):
        kw = {}
        if not url.startswith("sqlite"):
            # a stalled DB must not pin an executor thread for ever: connect bounded, and EVERY statement bounded
            # server-side (C3B-C4: a row lock held elsewhere kept set_disconnected 3 s+; 4 such calls fill the pool's
            # executor threads and every db_call after them times out). The migration lifts it for its VALIDATE.
            kw = dict(pool_size=pool_size, max_overflow=2, pool_pre_ping=True, pool_recycle=1800,
                      connect_args={"connect_timeout": 5, "options": "-c statement_timeout=5000"})
        self.engine = sa.create_engine(url, future=True, **kw)
        self.is_pg = self.engine.dialect.name == "postgresql"

    # -- start-up ------------------------------------------------------------------------------
    def schema_ready(self) -> list[str]:
        """Return the SCHEMA_TABLES that do not exist yet (empty = ready)."""
        insp = sa.inspect(self.engine)
        have = set(insp.get_table_names())
        return [t for t in SCHEMA_TABLES if t not in have]

    def fk_states(self) -> dict[str, str | None]:
        """{constraint: confdeltype or None if absent}; 'r' = RESTRICT, 'c' = CASCADE. Postgres only."""
        if not self.is_pg:
            return {name: "r" for _, name, _ in RECORD_FKS}
        out: dict[str, str | None] = {}
        with self.engine.connect() as c:
            for table, name, _col in RECORD_FKS:
                row = c.execute(text(
                    "SELECT confdeltype, convalidated FROM pg_constraint "
                    "WHERE conname = :n AND conrelid = CAST(:t AS regclass) AND contype = 'f'"
                ), {"n": name, "t": table}).first()
                out[name] = None if row is None else (row[0] if row[1] else row[0] + "?")
        return out

    def migrate_record_fks(self) -> dict[str, str]:
        """M10: make the three record FKs ON DELETE RESTRICT. Idempotent: reads confdeltype first and
        does nothing when already 'r' and validated. Two transactions per FK (NOT VALID, then VALIDATE),
        each under lock_timeout 5 s; the caller retries with backoff on OperationalError. Returns
        {constraint: 'already'|'migrated'}."""
        if not self.is_pg:
            return {name: "already" for _, name, _ in RECORD_FKS}
        res: dict[str, str] = {}
        states = self.fk_states()
        for table, name, col in RECORD_FKS:
            if states.get(name) == "r":
                res[name] = "already"
                continue
            with self.engine.begin() as c:
                c.execute(text("SET LOCAL lock_timeout = '5s'"))
                c.execute(text(f'ALTER TABLE "{table}" DROP CONSTRAINT IF EXISTS "{name}"'))
                c.execute(text(
                    f'ALTER TABLE "{table}" ADD CONSTRAINT "{name}" FOREIGN KEY ("{col}") '
                    f'REFERENCES euds(uid) ON DELETE RESTRICT NOT VALID'))
            with self.engine.begin() as c:
                c.execute(text("SET LOCAL lock_timeout = '5s'"))
                c.execute(text("SET LOCAL statement_timeout = 0"))   # VALIDATE scans the table: no 5 s cap here
                c.execute(text(f'ALTER TABLE "{table}" VALIDATE CONSTRAINT "{name}"'))
            res[name] = "migrated"
        return res

    def resumed_jobs(self) -> list[str]:
        """M10 watch: retention jobs whose persisted next_run_time is not NULL (= resumed)."""
        with self.engine.connect() as c:
            rows = c.execute(text(
                "SELECT id FROM apscheduler_jobs WHERE next_run_time IS NOT NULL AND id IN :ids"
            ).bindparams(sa.bindparam("ids", expanding=True)), {"ids": list(RETENTION_JOBS)}).all()
        return sorted(r[0] for r in rows)

    # -- identity ------------------------------------------------------------------------------
    def user_by_name(self, username: str) -> tuple[int, bool] | None:
        with self.engine.connect() as c:
            row = c.execute(text('SELECT id, active FROM "user" WHERE username = :u'), {"u": username}).first()
        return None if row is None else (int(row[0]), bool(row[1]))

    def eud(self, uid: str) -> dict | None:
        with self.engine.connect() as c:
            row = c.execute(text(
                "SELECT id, uid, callsign, user_id, last_status, last_event_time, device, os, platform, version, "
                "phone_number, team_id, team_role FROM euds WHERE uid = :u"), {"u": uid}).mappings().first()
        return None if row is None else dict(row)

    def eud_has_history(self, uid: str) -> bool:
        """'history' = any cot, points or geochat row of the uid (design M4/M10)."""
        with self.engine.connect() as c:
            for table, col in (("cot", "sender_uid"), ("points", "device_uid"), ("geochat", "sender_uid")):
                n = c.execute(text(f"SELECT 1 FROM {table} WHERE {col} = :u LIMIT 1"), {"u": uid}).first()
                if n is not None:
                    return True
        return False

    def callsign_free(self, callsign: str, uid: str) -> bool:
        with self.engine.connect() as c:
            row = c.execute(text("SELECT uid FROM euds WHERE callsign = :c"), {"c": callsign}).first()
        return row is None or row[0] == uid

    # -- rows ----------------------------------------------------------------------------------
    def write_eud(self, uid: str, user_id: int | None, callsign: str | None, device: str | None, os_: str | None,
                  platform: str | None, version: str | None, phone: str | None, group_name: str | None,
                  group_role: str | None, event_start: _dt.datetime | None, adopt: bool) -> str:
        """M5 defensive write of the identification metadata. Returns 'inserted' | 'updated' | 'owned-elsewhere'.
        - callsign written only when free (euds.callsign UNIQUE);
        - phone reduced to digits; strings cut to 255; team created if named;
        - user_id written only when `adopt` (a new row or an adopted unowned row) — never over another user:
          an adopting UPDATE is guarded by `user_id IS NULL OR user_id = :user_id`; when it matches no row the row
          was taken by another user first and 'owned-elsewhere' is returned, nothing written (SEC-1).
        """
        cs = _cut(callsign) if (callsign and self.callsign_free(callsign, uid)) else None
        team_id = self._team_id(group_name) if group_name else None
        vals = {
            "uid": uid, "callsign": cs, "device": _cut(device), "os": _cut(os_), "platform": _cut(platform),
            "version": _cut(version), "phone_number": phone_digits(phone),
            "last_event_time": event_start or _dt.datetime.now(_dt.timezone.utc).replace(tzinfo=None),
            "last_status": "Connected", "team_id": team_id, "team_role": _cut(group_role),
        }
        with self.engine.begin() as c:
            # insert-or-nothing in ONE statement: no SELECT-then-INSERT race with a concurrent writer of the row
            r = c.execute(text(
                "INSERT INTO euds (uid, callsign, device, os, platform, version, phone_number, last_event_time, "
                "last_status, user_id, team_id, team_role) VALUES (:uid, :callsign, :device, :os, :platform, "
                ":version, :phone_number, :last_event_time, :last_status, :user_id, :team_id, :team_role) "
                "ON CONFLICT (uid) DO NOTHING"), dict(vals, user_id=user_id))
            if r.rowcount == 1:
                return "inserted"
            sets = ("device=:device, os=:os, platform=:platform, version=:version, phone_number=:phone_number, "
                    "last_event_time=:last_event_time, last_status=:last_status, team_id=:team_id, team_role=:team_role")
            if cs is not None:
                sets += ", callsign=:callsign"
            where = "uid = :uid"
            if adopt:
                sets += ", user_id=:user_id"
                vals["user_id"] = user_id
                where += " AND (user_id IS NULL OR user_id = :user_id)"
            r = c.execute(text(f"UPDATE euds SET {sets} WHERE {where}"), vals)
            return "updated" if r.rowcount == 1 else "owned-elsewhere"

    def minimal_eud(self, uid: str, user_id: int | None, callsign: str | None, adopt: bool) -> str:
        """M5 fallback: the smallest row cot_parser's FK accepts. Same return values and the same adopt guard as
        write_eud (SEC-1)."""
        cs = _cut(callsign) if (callsign and self.callsign_free(callsign, uid)) else None
        now = _dt.datetime.now(_dt.timezone.utc).replace(tzinfo=None)
        with self.engine.begin() as c:
            r = c.execute(text("INSERT INTO euds (uid, callsign, last_status, last_event_time, user_id) "
                               "VALUES (:u, :c, 'Connected', :t, :uid_) ON CONFLICT (uid) DO NOTHING"),
                          {"u": uid, "c": cs, "t": now, "uid_": user_id if adopt else None})
            if r.rowcount == 1:
                return "inserted"
            r = c.execute(text("UPDATE euds SET last_status='Connected', last_event_time=:t" +
                               (", user_id=:uid_ WHERE uid=:u AND (user_id IS NULL OR user_id=:uid_)" if adopt
                                else " WHERE uid=:u")),
                          {"u": uid, "t": now, "uid_": user_id})
            return "updated" if r.rowcount == 1 else "owned-elsewhere"

    def _team_id(self, name: str) -> int | None:
        name = _cut(name)
        try:
            with self.engine.begin() as c:
                row = c.execute(text("SELECT id FROM teams WHERE name = :n"), {"n": name}).first()
                if row is not None:
                    return int(row[0])
                chat = c.execute(text("SELECT id FROM chatrooms WHERE name = :n"), {"n": name}).first()
                c.execute(text("INSERT INTO teams (name, chatroom_id) VALUES (:n, :cid)"),
                          {"n": name, "cid": None if chat is None else chat[0]})
                row = c.execute(text("SELECT id FROM teams WHERE name = :n"), {"n": name}).first()
                return None if row is None else int(row[0])
        except sa.exc.SQLAlchemyError as e:   # a team is cosmetic: never fail the row for it
            log.warning("team %r not written: %s", name, e)
            return None

    # -- presence (M8) ---------------------------------------------------------------------------
    def set_connected(self, uid: str, event_start: _dt.datetime | None) -> bool:
        """Re-assert Connected (+ the phone's SA start) when the row differs; True if it changed."""
        with self.engine.begin() as c:
            row = c.execute(text("SELECT last_status, last_event_time FROM euds WHERE uid=:u"), {"u": uid}).first()
            if row is None:
                return False
            have_t = _as_dt(row[1])
            want_t = event_start or have_t
            if row[0] == "Connected" and (event_start is None or have_t == event_start):
                return False
            c.execute(text("UPDATE euds SET last_status='Connected', last_event_time=:t WHERE uid=:u"),
                      {"u": uid, "t": want_t})
            return True

    def set_disconnected(self, uids: list[str], statement_timeout_ms: int | None = None) -> int:
        """Disconnected with last_event_time = max(last SA start, now) (B2-12). M13 passes a 1 s statement
        timeout so a stalled DB cannot eat the stop budget."""
        if not uids:
            return 0
        now = _dt.datetime.now(_dt.timezone.utc).replace(tzinfo=None)
        with self.engine.begin() as c:
            if statement_timeout_ms and self.is_pg:
                c.execute(text(f"SET LOCAL statement_timeout = {int(statement_timeout_ms)}"))
            n = 0
            for u in uids:
                r = c.execute(text(
                    "UPDATE euds SET last_status='Disconnected', last_event_time=" +
                    ("GREATEST(last_event_time, CAST(:t AS timestamp))" if self.is_pg else "MAX(COALESCE(last_event_time, :t), :t)") +
                    " WHERE uid=:u"), {"u": u, "t": now})
                n += r.rowcount or 0
        return n

    def sweep_connected(self) -> int:
        """At start, before the listeners: every Connected row -> Disconnected, GREATEST(t, now)."""
        now = _dt.datetime.now(_dt.timezone.utc).replace(tzinfo=None)
        with self.engine.begin() as c:
            r = c.execute(text(
                "UPDATE euds SET last_status='Disconnected', last_event_time=" +
                ("GREATEST(last_event_time, CAST(:t AS timestamp))" if self.is_pg else "MAX(COALESCE(last_event_time, :t), :t)") +
                " WHERE last_status='Connected'"), {"t": now})
        return r.rowcount or 0

    # -- bindings (M9) ---------------------------------------------------------------------------
    def needed_bindings(self, uid: str, user_id: int | None, callsign_usable: str | None) -> set[tuple[str, str, str]]:
        """The set of (exchange, queue, routing_key) a live device needs, computed from the DB."""
        need: set[tuple[str, str, str]] = {("dms", uid, uid), ("missions", uid, "missions")}
        if callsign_usable:
            need.add(("dms", callsign_usable, callsign_usable))
        with self.engine.connect() as c:
            groups = []
            if user_id is not None:
                groups = [r[0] for r in c.execute(text(
                    "SELECT g.name FROM groups_users gu JOIN groups g ON g.id = gu.group_id "
                    "WHERE gu.user_id = :uid AND gu.direction = 'OUT' AND gu.enabled"), {"uid": user_id}).all()]
            if groups:
                for g in groups:
                    need.add(("groups", uid, f"{g}.OUT"))
            else:
                need.add(("groups", uid, "__ANON__.OUT"))
            for r in c.execute(text("SELECT mission_name FROM mission_roles WHERE \"clientUid\" = :u "
                                    "AND mission_name IS NOT NULL"), {"u": uid}).all():
                need.add(("missions", uid, f"missions.{r[0]}"))
        return need

    def candidate_bindings(self, uid: str) -> set[tuple[str, str, str]]:
        """Every binding the gateway could ever have placed on the uid queue (for the unbind at
        identification after a crash, B2-13): all groups' .OUT (incl. __ANON__) and all missions."""
        cand: set[tuple[str, str, str]] = {("groups", uid, "__ANON__.OUT")}
        with self.engine.connect() as c:
            for r in c.execute(text("SELECT name FROM groups")).all():
                cand.add(("groups", uid, f"{r[0]}.OUT"))
            for r in c.execute(text("SELECT name FROM missions")).all():
                cand.add(("missions", uid, f"missions.{r[0]}"))
        return cand

    # -- web map (M8) ----------------------------------------------------------------------------
    def eud_json(self, uid: str) -> dict | None:
        """The fields of EUD.to_json() the web map uses (models/EUD.py:71-99), built from the row."""
        with self.engine.connect() as c:
            row = c.execute(text(
                "SELECT e.uid, e.callsign, e.device, e.os, e.platform, e.version, e.phone_number, e.last_event_time, "
                "e.last_status, e.team_role, u.username, t.name AS team FROM euds e "
                "LEFT JOIN \"user\" u ON u.id = e.user_id LEFT JOIN teams t ON t.id = e.team_id WHERE e.uid = :u"),
                {"u": uid}).mappings().first()
        if row is None:
            return None
        let = _as_dt(row["last_event_time"])
        if isinstance(let, _dt.datetime):
            let = let.strftime("%Y-%m-%dT%H:%M:%S.") + "%03dZ" % (let.microsecond // 1000)
        return {
            "uid": row["uid"], "callsign": row["callsign"], "device": row["device"], "os": row["os"],
            "platform": row["platform"], "version": row["version"], "phone_number": row["phone_number"],
            "last_event_time": let, "last_status": row["last_status"], "username": row["username"],
            "last_point": None, "team": row["team"], "team_color": None, "team_role": row["team_role"],
            "data_packages": None, "config_hash": None,
        }

"""M10 against a REAL Postgres (skipped unless PG_URL is set): the two-transaction RESTRICT migration is
idempotent, reads confdeltype first, and the Postgres-only SQL (GREATEST, expanding IN, "clientUid") runs.

  docker run -d --name pg289 -e POSTGRES_USER=ots -e POSTGRES_PASSWORD=password -e POSTGRES_DB=ots -p 127.0.0.1:15432:5432 postgres:16-alpine
  PG_URL=postgresql+psycopg://ots:password@127.0.0.1:15432/ots pytest tests/test_migration_pg.py
"""
import datetime as dt
import os

import pytest
import sqlalchemy as sa
from sqlalchemy import text

from batman_eud_gateway.db import Database

PG_URL = os.environ.get("PG_URL")
pytestmark = pytest.mark.skipif(not PG_URL, reason="PG_URL not set")

SCHEMA = """
DROP TABLE IF EXISTS geochat, points, cot, mission_roles, groups_users, groups, missions, apscheduler_jobs, euds, teams, chatrooms, "user" CASCADE;
CREATE TABLE "user" (id SERIAL PRIMARY KEY, username VARCHAR(255), active BOOLEAN);
CREATE TABLE teams (id SERIAL PRIMARY KEY, name VARCHAR(255), chatroom_id INTEGER);
CREATE TABLE chatrooms (id SERIAL PRIMARY KEY, name VARCHAR(255));
CREATE TABLE euds (id SERIAL PRIMARY KEY, uid VARCHAR(255) NOT NULL UNIQUE, callsign VARCHAR(255) UNIQUE,
  device VARCHAR(255), os VARCHAR(255), platform VARCHAR(255), version VARCHAR(255), phone_number BIGINT,
  last_event_time TIMESTAMP, last_status VARCHAR(255), user_id INTEGER, team_id INTEGER, team_role VARCHAR(255));
CREATE TABLE cot (id SERIAL PRIMARY KEY, sender_uid VARCHAR(255), timestamp TIMESTAMP,
  CONSTRAINT cot_eud FOREIGN KEY (sender_uid) REFERENCES euds(uid) ON DELETE CASCADE);
CREATE TABLE points (id SERIAL PRIMARY KEY, device_uid VARCHAR(255),
  CONSTRAINT point_eud FOREIGN KEY (device_uid) REFERENCES euds(uid) ON DELETE CASCADE);
CREATE TABLE geochat (id SERIAL PRIMARY KEY, sender_uid VARCHAR(255),
  CONSTRAINT geochat_eud FOREIGN KEY (sender_uid) REFERENCES euds(uid) ON DELETE CASCADE);
CREATE TABLE apscheduler_jobs (id VARCHAR(191) PRIMARY KEY, next_run_time DOUBLE PRECISION, job_state BYTEA);
CREATE TABLE groups (id SERIAL PRIMARY KEY, name VARCHAR(255) UNIQUE);
CREATE TABLE groups_users (user_id INTEGER, group_id INTEGER, direction VARCHAR(255), enabled BOOLEAN);
CREATE TABLE missions (id SERIAL PRIMARY KEY, name VARCHAR(255));
CREATE TABLE mission_roles (id SERIAL PRIMARY KEY, "clientUid" VARCHAR(255), username VARCHAR(255),
  "createTime" TIMESTAMP, role_type VARCHAR(255), mission_name VARCHAR(255), mission_guid VARCHAR(255));
INSERT INTO "user" (username, active) VALUES ('alice', true);
INSERT INTO groups (name) VALUES ('__ANON__'), ('Blue');
INSERT INTO groups_users VALUES (1, 2, 'OUT', true);
INSERT INTO missions (name) VALUES ('m1');
INSERT INTO mission_roles ("clientUid", username, "createTime", role_type, mission_name) VALUES ('A1', 'alice', now(), 'MISSION_SUBSCRIBER', 'm1');
INSERT INTO apscheduler_jobs (id, next_run_time) VALUES ('delete_old_data', NULL), ('purge_data', NULL);
"""


@pytest.fixture
def pg():
    d = Database(PG_URL)
    with d.engine.begin() as c:
        for stmt in SCHEMA.strip().split(";"):
            if stmt.strip():
                c.execute(text(stmt))
    return d


def test_migration_idempotent_and_validated(pg):
    assert pg.is_pg
    assert pg.fk_states() == {"cot_eud": "c", "point_eud": "c", "geochat_eud": "c"}
    assert pg.migrate_record_fks() == {"cot_eud": "migrated", "point_eud": "migrated", "geochat_eud": "migrated"}
    assert pg.fk_states() == {"cot_eud": "r", "point_eud": "r", "geochat_eud": "r"}
    pg.migrate_record_fks()                       # its VALIDATE runs with statement_timeout lifted
    assert set(pg.fk_states().values()) == {"r"}
    # RESTRICT holds: a device with history cannot be deleted; one without can
    pg.minimal_eud("A1", 1, None, adopt=True)
    pg.minimal_eud("A2", 1, None, adopt=True)
    with pg.engine.begin() as c:
        c.execute(text("INSERT INTO cot (sender_uid) VALUES ('A1')"))
    with pytest.raises(sa.exc.IntegrityError):
        with pg.engine.begin() as c:
            c.execute(text("DELETE FROM euds WHERE uid='A1'"))
    with pg.engine.begin() as c:
        c.execute(text("DELETE FROM euds WHERE uid='A2'"))
    assert pg.eud("A1") is not None and pg.eud("A2") is None


def test_pg_only_sql_paths(pg):
    pg.write_eud("A1", 1, "ALPHA", "Pixel", "34", "ATAK", "5", "555-123-4567", "Cyan", "Lead", dt.datetime(2026, 10, 14, 1, 0), adopt=True)
    assert pg.resumed_jobs() == []
    with pg.engine.begin() as c:
        c.execute(text("UPDATE apscheduler_jobs SET next_run_time = 1.0 WHERE id = 'delete_old_data'"))
    assert pg.resumed_jobs() == ["delete_old_data"]
    need = pg.needed_bindings("A1", 1, "ALPHA")
    assert ("groups", "A1", "Blue.OUT") in need and ("missions", "A1", "missions.m1") in need
    assert ("groups", "A1", "__ANON__.OUT") in pg.candidate_bindings("A1")
    # GREATEST keeps the phone time (2026-10) over a node clock in the past — simulate by a far-future SA time
    with pg.engine.begin() as c:
        c.execute(text("UPDATE euds SET last_event_time = '2099-01-01' WHERE uid='A1'"))
    assert pg.set_disconnected(["A1"]) == 1
    assert pg.eud("A1")["last_event_time"].year == 2099
    assert pg.set_connected("A1", None)
    assert pg.sweep_connected() == 1 and pg.sweep_connected() == 0
    j = pg.eud_json("A1")
    assert j["username"] == "alice" and j["team"] == "Cyan"


def test_every_statement_is_bounded_server_side(pg):
    """C3B-C4: a query that waits on another session's row lock is cancelled by the server after 5 s (it held an
    executor thread for as long as the lock lived), while the migration's VALIDATE is exempt."""
    import time
    pg.write_eud("LOCKED", None, None, None, None, None, None, None, None, None, None, adopt=False)
    other = sa.create_engine(PG_URL, future=True)
    with other.connect() as c:
        t = c.begin()
        c.execute(text("SELECT 1 FROM euds WHERE uid='LOCKED' FOR UPDATE"))
        t0 = time.monotonic()
        with pytest.raises(sa.exc.OperationalError) as e:
            pg.set_disconnected(["LOCKED"])
        took = time.monotonic() - t0
        t.rollback()
    other.dispose()
    assert "statement timeout" in str(e.value) and 4.5 <= took <= 8, (took, str(e.value)[:120])
    pg.migrate_record_fks()                       # its VALIDATE runs with statement_timeout lifted
    assert set(pg.fk_states().values()) == {"r"}

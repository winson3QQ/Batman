import datetime as dt

import pytest
import sqlalchemy as sa
from sqlalchemy import text

from batman_eud_gateway.db import Database

SCHEMA = """
CREATE TABLE "user" (id INTEGER PRIMARY KEY, username VARCHAR(255), active BOOLEAN);
CREATE TABLE teams (id INTEGER PRIMARY KEY, name VARCHAR(255), chatroom_id INTEGER);
CREATE TABLE chatrooms (id INTEGER PRIMARY KEY, name VARCHAR(255));
CREATE TABLE euds (id INTEGER PRIMARY KEY, uid VARCHAR(255) NOT NULL UNIQUE, callsign VARCHAR(255) UNIQUE,
  device VARCHAR(255), os VARCHAR(255), platform VARCHAR(255), version VARCHAR(255), phone_number BIGINT,
  last_event_time TIMESTAMP, last_status VARCHAR(255), user_id INTEGER, team_id INTEGER, team_role VARCHAR(255),
  meshtastic_id BIGINT, meshtastic_macaddr VARCHAR(255), last_meshtastic_publish TIMESTAMP);
CREATE TABLE cot (id INTEGER PRIMARY KEY, sender_uid VARCHAR(255), timestamp TIMESTAMP);
CREATE TABLE points (id INTEGER PRIMARY KEY, device_uid VARCHAR(255));
CREATE TABLE geochat (id INTEGER PRIMARY KEY, sender_uid VARCHAR(255));
CREATE TABLE apscheduler_jobs (id VARCHAR(191) PRIMARY KEY, next_run_time DOUBLE PRECISION, job_state BLOB);
CREATE TABLE groups (id INTEGER PRIMARY KEY, name VARCHAR(255) UNIQUE);
CREATE TABLE groups_users (user_id INTEGER, group_id INTEGER, direction VARCHAR(255), enabled BOOLEAN);
CREATE TABLE missions (id INTEGER PRIMARY KEY, name VARCHAR(255));
CREATE TABLE mission_roles (id INTEGER PRIMARY KEY, "clientUid" VARCHAR(255), username VARCHAR(255),
  "createTime" TIMESTAMP, role_type VARCHAR(255), mission_name VARCHAR(255), mission_guid VARCHAR(255));
"""


@pytest.fixture
def db(tmp_path):
    d = Database(f"sqlite:///{tmp_path}/ots.sqlite")
    with d.engine.begin() as c:
        for stmt in SCHEMA.strip().split(";"):
            if stmt.strip():
                c.execute(text(stmt))
        c.execute(text('INSERT INTO "user" (id, username, active) VALUES (1, "alice", 1), (2, "bob", 1), (3, "carol", 0)'))
        c.execute(text("INSERT INTO groups (id, name) VALUES (1, '__ANON__'), (2, 'Blue'), (3, 'Red')"))
        c.execute(text("INSERT INTO groups_users VALUES (1, 2, 'OUT', 1), (1, 3, 'OUT', 0), (1, 2, 'IN', 1)"))
        c.execute(text("INSERT INTO missions (id, name) VALUES (1, 'm1'), (2, 'm2')"))
        c.execute(text("INSERT INTO mission_roles (\"clientUid\", username, \"createTime\", role_type, mission_name) "
                       "VALUES ('A1', 'alice', :t, 'MISSION_SUBSCRIBER', 'm1')"), {"t": dt.datetime(2026, 1, 1)})
        c.execute(text("INSERT INTO apscheduler_jobs (id, next_run_time) VALUES ('delete_old_data', NULL), ('purge_data', NULL)"))
    return d

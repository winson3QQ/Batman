import datetime as dt

from sqlalchemy import text

from batman_eud_gateway.db import phone_digits


def test_schema_ready_and_jobs(db):
    assert db.schema_ready() == []
    assert db.resumed_jobs() == []
    with db.engine.begin() as c:
        c.execute(text("UPDATE apscheduler_jobs SET next_run_time = 1.0 WHERE id='purge_data'"))
    assert db.resumed_jobs() == ["purge_data"]


def test_user_lookup(db):
    assert db.user_by_name("alice") == (1, True)
    assert db.user_by_name("carol") == (3, False)
    assert db.user_by_name("nobody") is None


def test_write_eud_insert_then_update_defensive(db):
    r = db.write_eud("A1", 1, "ALPHA", "Pixel", "x" * 300, "ATAK-CIV", "5.1", "555-123-4567", "Cyan", "Team Member",
                     dt.datetime(2026, 10, 14, 1, 0), adopt=True)
    assert r == "inserted"
    row = db.eud("A1")
    assert row["user_id"] == 1 and row["callsign"] == "ALPHA" and row["phone_number"] == 5551234567
    assert len(row["os"]) == 255 and row["last_status"] == "Connected" and row["team_id"] is not None
    # a second device with the same callsign: recorded WITHOUT the callsign (UNIQUE)
    r = db.write_eud("A2", 2, "ALPHA", None, None, None, None, None, None, None, None, adopt=True)
    assert r == "inserted" and db.eud("A2")["callsign"] is None and db.eud("A2")["user_id"] == 2
    # update without adopt never touches user_id
    db.write_eud("A1", 2, "ALPHA", "Pixel2", None, None, None, None, None, None, None, adopt=False)
    assert db.eud("A1")["user_id"] == 1 and db.eud("A1")["device"] == "Pixel2"


def test_minimal_row_and_history(db):
    db.minimal_eud("M1", 1, None, adopt=True)
    assert db.eud("M1")["user_id"] == 1 and db.eud("M1")["last_status"] == "Connected"
    assert not db.eud_has_history("M1")
    with db.engine.begin() as c:
        c.execute(text("INSERT INTO geochat (sender_uid) VALUES ('M1')"))
    assert db.eud_has_history("M1")


def test_presence(db):
    db.minimal_eud("P1", 1, None, adopt=True)
    t = dt.datetime(2026, 10, 14, 2, 0)
    assert db.set_connected("P1", t)          # time differs -> changed
    assert not db.set_connected("P1", t)      # same -> no write
    assert db.set_disconnected(["P1", "nope"]) == 1
    row = db.eud("P1")
    assert row["last_status"] == "Disconnected"
    assert db.set_connected("P1", None)       # status differs -> changed, time kept
    assert db.eud("P1")["last_event_time"] is not None
    assert db.sweep_connected() == 1
    assert db.eud("P1")["last_status"] == "Disconnected"
    assert db.sweep_connected() == 0


def test_needed_and_candidate_bindings(db):
    db.minimal_eud("A1", 1, "ALPHA", adopt=True)
    need = db.needed_bindings("A1", 1, "ALPHA")
    assert ("groups", "A1", "Blue.OUT") in need            # enabled OUT membership
    assert ("groups", "A1", "Red.OUT") not in need         # disabled
    assert ("groups", "A1", "Blue.IN") not in need         # IN direction never
    assert ("groups", "A1", "__ANON__.OUT") not in need    # has groups -> no anon
    assert ("missions", "A1", "missions.m1") in need and ("missions", "A1", "missions") in need
    assert ("dms", "A1", "A1") in need and ("dms", "ALPHA", "ALPHA") in need
    # a user without memberships -> __ANON__
    need2 = db.needed_bindings("B1", 2, None)
    assert ("groups", "B1", "__ANON__.OUT") in need2 and ("dms", "B1", "B1") in need2
    cand = db.candidate_bindings("A1")
    assert {("groups", "A1", "__ANON__.OUT"), ("groups", "A1", "Blue.OUT"), ("groups", "A1", "Red.OUT"),
            ("missions", "A1", "missions.m1"), ("missions", "A1", "missions.m2")} <= cand


def test_eud_json_shape(db):
    db.write_eud("J1", 1, "JAY", "Pixel", "34", "ATAK", "5", None, "Cyan", "Lead", dt.datetime(2026, 1, 2, 3, 4, 5), adopt=True)
    j = db.eud_json("J1")
    assert j["username"] == "alice" and j["team"] == "Cyan" and j["last_event_time"] == "2026-01-02T03:04:05.000Z"
    assert set(j) >= {"uid", "callsign", "last_status", "last_point", "data_packages", "config_hash"}


def test_phone_digits():
    assert phone_digits("555-123-4567") == 5551234567
    assert phone_digits("+886 912 345 678") == 886912345678
    assert phone_digits("n/a") is None and phone_digits(None) is None
    assert phone_digits("1" * 30) is None

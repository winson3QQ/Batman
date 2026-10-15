"""SEC-11: verify-profile-ots-record.sh — a persistent UNKNOWN becomes DRIFT after UNKNOWN_MAX_S; a definite verdict
clears the streak. Runs the real script under sh with a fake `docker` (DB not running) and a fake rundir helper
pointing at a temp dir, and a fake /proc/uptime via PATH-shadowed `cut` is avoided: the streak start is planted."""
import os
import pathlib
import subprocess

import pytest

SCRIPT = pathlib.Path(__file__).resolve().parents[2] / "verify-profile-ots-record.sh"


def run(tmp_path, docker_body, plant=None, max_s="600"):
    bin_ = tmp_path / "bin"; bin_.mkdir(exist_ok=True)
    (bin_ / "docker").write_text("#!/bin/sh\n" + docker_body + "\n"); (bin_ / "docker").chmod(0o755)
    rund = tmp_path / "run"; rund.mkdir(exist_ok=True)
    helper = tmp_path / "rundir.sh"
    helper.write_text(f'batman_rundir(){{ RUNDIR="{rund}"; return 0; }}\n')
    src = SCRIPT.read_text(encoding="utf-8").replace("/usr/lib/batman/rundir.sh", str(helper))
    s = tmp_path / "rec.sh"; s.write_text(src)
    if plant is not None:
        up = int(float(open("/proc/uptime").read().split()[0]))
        (rund / "batman-ots-record-unknown-since").write_text(str(up - plant) + "\n")
    env = dict(os.environ, PATH=f"{bin_}:{os.environ['PATH']}", UNKNOWN_MAX_S=max_s)
    r = subprocess.run(["sh", str(s)], capture_output=True, text=True, env=env, timeout=30)
    return r.returncode, r.stdout.strip(), rund


NOT_RUNNING = 'case "$1" in inspect) echo false ;; esac'
HEALTHY = ('case "$1" in inspect) echo true ;; exec) case "$*" in *pg_constraint*) echo "cot_eud=r,geochat_eud=r,point_eud=r" ;; '
           '*) echo "" ;; esac ;; esac')


def test_first_unknown_is_unknown_and_starts_the_streak(tmp_path):
    rc, out, rund = run(tmp_path, NOT_RUNNING)
    assert rc == 0 and "UNKNOWN" in out and (rund / "batman-ots-record-unknown-since").exists(), out


def test_unknown_older_than_the_window_is_drift(tmp_path):
    rc, out, _ = run(tmp_path, NOT_RUNNING, plant=700)
    assert rc == 1 and "DRIFT record check UNKNOWN" in out, out


def test_unknown_inside_the_window_stays_unknown(tmp_path):
    rc, out, _ = run(tmp_path, NOT_RUNNING, plant=100)
    assert rc == 0 and out.startswith("verify-profile-ots-record: UNKNOWN") and "DRIFT record check" not in out, out


def test_a_definite_verdict_clears_the_streak(tmp_path):
    rc, out, rund = run(tmp_path, HEALTHY, plant=700)
    assert rc == 0 and "OK" in out, out
    assert not (rund / "batman-ots-record-unknown-since").exists()

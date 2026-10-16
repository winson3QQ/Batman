#!/bin/sh
# verify-profile-ots-record.sh — the record's controls, as a guardian verdict (#289 M10, review A3-1).
# Run by the per-tenant guardian every tick next to verify-profile-ots.sh (payload-guardian-run.sh runs
# every verify-profile-*.sh in the golden dir; exit 1 = DRIFT).
#
# DRIFT (exit 1) only on a DEFINITE finding:
#   - one of the record's three foreign keys (cot_eud, point_eud, geochat_eud) is not ON DELETE RESTRICT
#     (confdeltype <> 'r'), i.e. the gateway's start migration has not run on this schema; or
#   - a retention job (delete_old_data, purge_data) is RESUMED: its persisted apscheduler_jobs row has a
#     non-NULL next_run_time (an API resume persists for ever regardless of config.yml — review B2-2).
# UNKNOWN (exit 0 + a log line, never a false DRIFT): the DB container is not running, psql fails, the
# relation does not exist yet (first boot), auth error, timeout (8 s).
# On the OTA trial boot that introduces the gateway the FKs are CASCADE until its migration ran: one DRIFT
# tick, OK after (design §4, B3-12).
# SEC-11: an UNKNOWN that persists is itself a finding (a broken psql, a changed password, a DB that never comes
# back: the record goes unwatched). The first UNKNOWN of a streak is remembered in the root-only run dir; one that
# has lasted UNKNOWN_MAX_S (600 s, the guardian's window) is DRIFT. A definite verdict (OK or DRIFT) clears it.
set -u
UNKNOWN_MAX_S=${UNKNOWN_MAX_S:-600}
# shellcheck source=/dev/null
[ -r /usr/lib/batman/rundir.sh ] && . /usr/lib/batman/rundir.sh   # #280: root-only run dir (RUNDIR)
SINCE=""
if type batman_rundir >/dev/null 2>&1 && batman_rundir 2>/dev/null; then SINCE="$RUNDIR/batman-ots-record-unknown-since"; fi
up_s(){ cut -d. -f1 /proc/uptime; }
unknown(){   # $1 = reason; exit 0 (UNKNOWN) or 1 (DRIFT: the streak is older than UNKNOWN_MAX_S)
	t0=""; [ -n "$SINCE" ] && t0=$(cat "$SINCE" 2>/dev/null)
	case "$t0" in ''|*[!0-9]*) t0=$(up_s); [ -n "$SINCE" ] && echo "$t0" > "$SINCE" ;; esac
	age=$(( $(up_s) - t0 ))
	if [ "$age" -ge "$UNKNOWN_MAX_S" ]; then
		echo "verify-profile-ots-record: DRIFT record check UNKNOWN for ${age} s ($1)"; exit 1
	fi
	echo "verify-profile-ots-record: UNKNOWN ($1; ${age} s of ${UNKNOWN_MAX_S} s before DRIFT)"; exit 0
}
known(){ [ -n "$SINCE" ] && rm -f "$SINCE"; }
DB=ots-db
# confdeltype is "char": cast it, or PG 16 says `operator is not unique: text || "char"` (seen on 04, rc 3)
Q_FK="SELECT string_agg(conname || '=' || confdeltype::text, ',' ORDER BY conname) FROM pg_constraint WHERE contype='f' AND conname IN ('cot_eud','point_eud','geochat_eud');"
Q_JOBS="SELECT coalesce(string_agg(id, ',' ORDER BY id), '') FROM apscheduler_jobs WHERE id IN ('delete_old_data','purge_data') AND next_run_time IS NOT NULL;"

if [ "$(docker inspect -f '{{.State.Running}}' "$DB" 2>/dev/null)" != true ]; then
	unknown "$DB not running"
fi
# bounded without timeout(1): the node's busybox has no timeout applet (rc 1 on 04: "timeout: not found" made every
# tick UNKNOWN, so a resumed job was never DRIFT). The server side is bounded by statement_timeout; the docker CLI by
# a watchdog that kills it after 10 s (its stdout is /dev/null, so it never holds the $(...) open).
run_q(){
	( docker exec -e PGOPTIONS='-c statement_timeout=8000' "$DB" psql -U ots -d ots -Atq -v ON_ERROR_STOP=1 -c "$1" 2>&1 &
	  p=$!
	  ( sleep 10; kill "$p" 2>/dev/null ) >/dev/null 2>&1 &
	  w=$!
	  wait "$p"; r=$?
	  kill "$w" 2>/dev/null
	  exit "$r" )
}

fk=$(run_q "$Q_FK"); rc=$?
if [ "$rc" -ne 0 ] || [ -z "$fk" ]; then
	unknown "fk query rc=$rc: $(echo "$fk" | head -1)"
fi
jobs=$(run_q "$Q_JOBS"); rc=$?
if [ "$rc" -ne 0 ]; then
	case "$jobs" in *"does not exist"*) unknown "apscheduler_jobs absent yet" ;; esac
	unknown "jobs query rc=$rc: $(echo "$jobs" | head -1)"
fi

known   # a definite verdict follows: the UNKNOWN streak (if any) is over
drift=0
case "$fk" in
	*cot_eud=r*geochat_eud=r*point_eud=r*) ;;
	*) echo "verify-profile-ots-record: DRIFT record FKs not RESTRICT: $fk"; drift=1 ;;
esac
# every one of the three must be present
for n in cot_eud point_eud geochat_eud; do
	case "$fk" in *"$n="*) ;; *) echo "verify-profile-ots-record: DRIFT fk $n absent"; drift=1 ;; esac
done
if [ -n "$jobs" ]; then
	echo "verify-profile-ots-record: DRIFT retention job RESUMED: $jobs"; drift=1
fi
[ "$drift" -eq 0 ] && echo "verify-profile-ots-record: OK (fks: $fk; no resumed job)"
exit "$drift"

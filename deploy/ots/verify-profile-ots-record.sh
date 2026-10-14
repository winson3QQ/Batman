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
set -u
DB=ots-db
Q_FK="SELECT string_agg(conname || '=' || confdeltype, ',' ORDER BY conname) FROM pg_constraint WHERE contype='f' AND conname IN ('cot_eud','point_eud','geochat_eud');"
Q_JOBS="SELECT coalesce(string_agg(id, ',' ORDER BY id), '') FROM apscheduler_jobs WHERE id IN ('delete_old_data','purge_data') AND next_run_time IS NOT NULL;"

if [ "$(docker inspect -f '{{.State.Running}}' "$DB" 2>/dev/null)" != true ]; then
	echo "verify-profile-ots-record: UNKNOWN ($DB not running)"; exit 0
fi
run_q(){ timeout 8 docker exec "$DB" psql -U ots -d ots -Atq -v ON_ERROR_STOP=1 -c "$1" 2>&1; }

fk=$(run_q "$Q_FK"); rc=$?
if [ "$rc" -ne 0 ] || [ -z "$fk" ]; then
	echo "verify-profile-ots-record: UNKNOWN (fk query rc=$rc: $(echo "$fk" | head -1))"; exit 0
fi
jobs=$(run_q "$Q_JOBS"); rc=$?
if [ "$rc" -ne 0 ]; then
	case "$jobs" in *"does not exist"*) echo "verify-profile-ots-record: UNKNOWN (apscheduler_jobs absent yet)"; exit 0 ;; esac
	echo "verify-profile-ots-record: UNKNOWN (jobs query rc=$rc: $(echo "$jobs" | head -1))"; exit 0
fi

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

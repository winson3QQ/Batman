#!/bin/bash
# tests/prov-p1/misc-insleep.sh — scripts/node/prov-misc-254.sh `insleep` under /proc churn (254-h23 §21.3 / §23.9): the scan
# of /proc/*/stat for a `sleep` child in the dry run's process group stays right while hundreds of short-lived processes
# come and go (a vanished /proc entry is skipped, never an error), and says NOSLEEP when the group has no sleep. Runs
# the node script's own code (busybox sh when present). Zero cases = FAIL.
set -u
REPO=$(cd "$(dirname "$0")/../.." && pwd); NS=$REPO/scripts/node/prov-misc-254.sh
SH=$(command -v busybox >/dev/null 2>&1 && echo "busybox sh" || echo sh)
T=$(mktemp -d); n=0; f=0; CH=""
cleanup(){ [ -n "$CH" ] && kill $CH 2>/dev/null; [ -n "${G:-}" ] && kill -- -"$G" 2>/dev/null; rm -rf "$T"; }
trap cleanup EXIT
want(){ n=$((n + 1)); if [ "$2" = "$3" ]; then echo "ok   $1 ($2)"; else echo "FAIL $1: [$2] want $3"; f=$((f + 1)); fi; }
# the script keeps its files next to itself; rundir.sh is sourced from /usr/lib/batman — point it at a stub via a copy
mkdir -p "$T/w"; sed 's#^\. /usr/lib/batman/rundir.sh#RUNDIR=/nonexistent; true#' "$NS" > "$T/w/prov-misc-254.sh"
grep -q '^RUNDIR=/nonexistent; true' "$T/w/prov-misc-254.sh" || { echo "FAIL could not stub rundir.sh in the copy"; exit 1; }
churn(){ while :; do for _ in 1 2 3 4 5 6 7 8; do /bin/true & done; wait; done; }
# a process group whose member sleeps in a loop, like the autocommit wait loop
setsid sh -c 'echo $$ > '"$T/w/pg.x"'; while :; do sleep 1; done' & sleep 0.5; G=$(cat "$T/w/pg.x")
churn & CH=$!
want "a sleeping group under churn -> INSLEEP" "$($SH "$T/w/prov-misc-254.sh" insleep x 2>&1 | tail -1)" INSLEEP
kill -- -"$G" 2>/dev/null; sleep 0.3
# a group without any sleep (a busy loop) -> NOSLEEP, also under churn (the scan gives up after its 30 s)
setsid sh -c 'echo $$ > '"$T/w/pg.y"'; while :; do :; done' & sleep 0.5; G=$(cat "$T/w/pg.y")
cp "$T/w/pg.y" "$T/w/pg.x"
want "a group with no sleep under churn -> NOSLEEP" "$($SH "$T/w/prov-misc-254.sh" insleep x 2>&1 | tail -1)" NOSLEEP
echo "MISC-INSLEEP cases=$n fails=$f"; [ "$n" -gt 0 ] && [ "$f" = 0 ]

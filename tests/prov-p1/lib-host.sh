#!/bin/bash
# tests/prov-p1/lib-host.sh — offline tests of scripts/dv/prov-254.sh host-side helpers (review 2026-10-28 A-M5, A-m5/B-m7):
#   pr_wait_held ends on the host clock when the node never answers (qr -> 255 forever), instead of looping;
#   pr_lock: free -> taken with an owner line; held by a live pid -> FAIL "holds … age"; held by a dead pid -> FAIL naming
#   it a stale lock with the rm command. No network. Zero cases = FAIL.
set -u
R=$(cd "$(dirname "$0")/../.." && pwd)
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT; n=0; f=0
want(){ n=$((n + 1)); case "$2" in $3) echo "ok   $1" ;; *) echo "FAIL $1: [$2] want $3"; f=$((f + 1)) ;; esac; }
export TEMP=$T PR_UNIT=prov-libtest-254
# shellcheck source=scripts/dv/prov-254.sh
. "$R/scripts/dv/prov-254.sh" >/dev/null 2>&1
# stubs: the node never answers; the host clock jumps 100 s per call (kept in a file: mono runs in $(…) subshells)
echo 0 > "$T/clk"
qr(){ return 255; }
mono(){ local c; c=$(cat "$T/clk"); c=$((c + 100)); echo $c > "$T/clk"; echo $c; }
sleep(){ :; }
declare -f qr mono sleep pr_wait_held > "$T/fn.sh"
o=$(T="$T" timeout 20 bash -c '. "$1"; pr_wait_held 480; echo "rc=$?"' _ "$T/fn.sh" 2>&1)   # the stubs read $T
want "pr_wait_held: an unreachable node ends on the host clock (rc 1, no endless loop)" "$o" '*no HELD and no node answer within 1080s (host clock)*rc=1'
# pr_lock (it exits on a conflict: run each in a subshell)
LOCKD=$T/lock.d
o=$( (pr_lock; echo TAKEN; cat "$LOCKD/owner") 2>&1 ); want "pr_lock: free -> taken, owner recorded" "$o" "TAKEN*prov-libtest-254*"
o=$( (pr_lock; echo TAKEN) 2>&1 ); want "pr_lock: held by a live pid -> FAIL holds, with its age" "$o" "FAIL another dv run holds $LOCKD*age*"
case "$o" in *"NOT alive"*) n=$((n + 1)); f=$((f + 1)); echo "FAIL a live owner was called stale";; esac
echo "999999 $(( $(date +%s) - 7200 )) prov-x-254 rX" > "$LOCKD/owner"
o=$( (pr_lock; echo TAKEN) 2>&1 ); want "pr_lock: a dead owner -> FAIL naming a stale lock + the rm command" "$o" "*pid 999999 is NOT alive: a stale lock*rm -rf*"
case "$o" in *TAKEN*) n=$((n + 1)); f=$((f + 1)); echo "FAIL a stale lock was taken over silently";; esac
pr_unlock; [ ! -e "$LOCKD" ] && { n=$((n + 1)); echo "ok   pr_unlock removes the lock and its owner file"; } || { n=$((n + 1)); f=$((f + 1)); echo "FAIL pr_unlock left $LOCKD"; }
# pr_wait_result (review B-m1): a detached job that outlives the first wait is waited for while alive, never treated as
# done; gone without a line -> ""; still alive / node silent at max -> ALIVE. qr stubbed from files; mono +100 per call.
wr(){ echo 0 > "$T/clk"; echo "$1" > "$T/res"; echo "$2" > "$T/alive"; echo "${3:-0}" > "$T/late"
	o=$(T="$T" timeout 20 bash -c '. "$1"; pr_wait_result /x/out /x/pid 120 600; echo "rc=$?"' _ "$T/fw.sh" 2>&1); }
qr(){ case "$1" in
	*RESULT=*) n=$(cat "$T/late"); if [ "$n" -gt 0 ]; then echo $((n - 1)) > "$T/late"; else cat "$T/res"; fi ;;
	*kill*) cat "$T/alive" ;; esac; }
declare -f qr mono sleep pr_wait_result > "$T/fw.sh"
wr "RESULT=PASS x" alive 3; want "pr_wait_result: the line arrives after a few polls" "$o" 'RESULT=PASS x*rc=0'
wr "" alive; want "pr_wait_result: alive past max -> ALIVE rc 2 (not done, not killed)" "$o" 'ALIVE*rc=2'
wr "" dead; want "pr_wait_result: gone without a line -> empty rc 1" "$o" '*rc=1'
wr "" ""; want "pr_wait_result: node silent -> ALIVE rc 2 (unknown is not dead)" "$o" 'ALIVE*rc=2'
echo "LIB-HOST cases=$n fails=$f"; [ "$n" -gt 0 ] && [ "$f" = 0 ]

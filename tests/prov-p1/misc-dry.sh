#!/bin/bash
# tests/prov-p1/misc-dry.sh — offline test of the dry-run arm machinery in scripts/node/prov-misc-254.sh (254-h23 §19.1,
# §20.1, §21.3, §22.3, §23.3) against a stub batman-autocommit (PATH) under a throwaway PRM_ROOT. busybox sh when present.
#   start: atomic pid file + presence (sid or output) -> STARTED; hold-consumed made only when absent, removed by stop
#   judge: ok; "hold present" after "gate until" -> INVALID; no "hold present" -> INVALID; no verdict within the cap ->
#          INVALID; a member left 15 s after the verdict -> INVALID, then stop -> KILLED (session gone)
#   inloop: the verdict >= 3 s after the gate line -> INLOOP (arm-a.<tag>.verdict); within 3 s -> TOOFAST
#   scan (churn white-box, §21.3): a 2-member session counted exactly while hundreds of short processes come and go;
#          a comm containing ") " parsed from the LAST ") "; no /proc/self -> INVALID
#   precond: hold-once / a live "batman-autocommit run" are named
#   save / restore: run-dir files the arm made are removed, the snapshot comes back -> RESTORED-SAME
# Zero cases = FAIL.
set -u
REPO=$(cd "$(dirname "$0")/../.." && pwd); M=$REPO/scripts/node/prov-misc-254.sh
SH=$(command -v busybox >/dev/null 2>&1 && echo "busybox sh" || echo sh)
T=$(mktemp -d); trap 'pkill -f "$T/" 2>/dev/null; rm -rf "$T"' EXIT; n=0; f=0
# shellcheck disable=SC2254  # $3 is a glob on purpose
want(){ n=$((n + 1)); case "$2" in $3) echo "ok   $1 ($(echo "$2" | head -1 | cut -c1-90))" ;; *) echo "FAIL $1: [$(echo "$2" | head -3 | tr '\n' '|')] want $3"; f=$((f + 1)) ;; esac; }
R=$T/root; W=$T/w
mkdir -p "$R/opt/batdata/state" "$R/opt/batdata/log" "$R/usr/lib/batman" "$R/run" "$W" "$T/bin"
echo "RUNDIR=$R/run" > "$R/usr/lib/batman/rundir.sh"
echo "$(cat /proc/sys/kernel/random/boot_id) helper claimed member 1 radio" > "$R/opt/batdata/state/prov-state"
printf 'a\nb\n' > "$R/opt/batdata/log/ota-trace.log"; printf 'x boot_id=aaaa1111\ny boot_id=bbbb2222\n' > "$R/opt/batdata/log/boot-reasons.log"
cp "$M" "$W/m.sh"
# the stub autocommit: its behaviour from $T/mode (lines it prints, sleeps, a lingering child)
cat > "$T/bin/batman-autocommit" <<'EOF'
#!/bin/sh
m=$(cat "$STUBMODE")
say(){ echo "batman-autocommit: $*"; }
case "$m" in
	ok)        say "hold present — this trial will not be reverted"; say "slot A is an uncommitted trial — gate until uptime 1s (now 5s), revert=0"; say "mesh join required: 0 (prov=member)" ;;
	order)     say "slot A is an uncommitted trial — gate until uptime 1s (now 5s), revert=0"; say "hold present — this trial will not be reverted"; say "mesh join required: 0 (prov=member)" ;;
	nohold)    say "slot A is an uncommitted trial — gate until uptime 1s (now 5s), revert=1"; say "mesh join required: 0 (prov=member)" ;;
	silent)    say "hold present — this trial will not be reverted"; sleep 20 ;;
	linger)    say "hold present — this trial will not be reverted"; say "slot A … gate until uptime 1s"; sleep 60 & say "mesh join required: 0 (prov=member)" ;;
	loop)      say "hold present — this trial will not be reverted"; say "slot A … gate until uptime 1s"; sleep 5; say "mesh join required: 1 (prov=member)" ;;
	fast)      say "hold present — this trial will not be reverted"; say "slot A … gate until uptime 1s"; say "mesh join required: 1 (prov=member)" ;;
esac
EOF
chmod 755 "$T/bin/batman-autocommit"
printf '#!/bin/sh\necho A\n' > "$T/bin/batman-slot"; chmod 755 "$T/bin/batman-slot"
mm(){ env PATH="$T/bin:$PATH" PRM_ROOT="$R" STUBMODE="$T/mode" "$@"; }
ms(){ mm $SH "$W/m.sh" "$@" 2>&1; }
arm(){ echo "$1" > "$T/mode"; ms start "$2"; }
want "save" "$(ms save)" 'SAVED*'
o=$(arm ok t1); want "start: STARTED with a numeric pid and presence" "$o" 'STARTED pid=[0-9]* present=*'
want "start: hold-consumed made (it was absent)" "$(ls "$R/run")" '*autocommit.hold-consumed*'
want "judge: ok" "$(ms judge t1 30 | head -1)" 'JUDGE ok del=*'
want "stop: nothing left" "$(ms stop t1)" STOPPED
want "stop: the hold-consumed this arm made is removed" "$(ls "$R/run")" ''
: > "$R/run/autocommit.hold-consumed"; arm ok t1b >/dev/null; ms judge t1b 30 >/dev/null; ms stop t1b >/dev/null
want "stop: a hold-consumed that was there before is kept" "$(ls "$R/run")" 'autocommit.hold-consumed'
rm -f "$R/run/autocommit.hold-consumed"
arm order t2 >/dev/null; want "judge: 'hold present' after 'gate until' -> INVALID" "$(ms judge t2 30 | head -1)" "JUDGE INVALID 'hold present' after 'gate until'*"; ms stop t2 >/dev/null
arm nohold t3 >/dev/null; want "judge: no 'hold present' line -> INVALID" "$(ms judge t3 30 | head -1)" 'JUDGE INVALID no *hold present*'; ms stop t3 >/dev/null
arm silent t4 >/dev/null; want "judge: no verdict line within the cap -> INVALID" "$(ms judge t4 3 | head -1)" 'JUDGE INVALID no verdict line within the 3s cap*'
want "stop: a member left -> KILLED" "$(ms stop t4)" 'KILLED*'
arm linger t5 >/dev/null; want "judge: a member 15 s after the verdict -> INVALID" "$(ms judge t5 30 | head -1)" 'JUDGE INVALID the session still had*'
want "stop after linger: KILLED" "$(ms stop t5)" 'KILLED*'
want "scan after stop: MEMBERS 0" "$(ms scan t5)" 'MEMBERS 0'
arm loop t6 >/dev/null; want "inloop: the verdict >= 3 s after the gate line -> INLOOP" "$(ms inloop t6)" INLOOP
want "inloop: written node-side to arm-a.t6.verdict" "$(cat "$W/arm-a.t6.verdict")" INLOOP
ms judge t6 30 >/dev/null; ms stop t6 >/dev/null
arm fast t7 >/dev/null; sleep 1; want "inloop: the verdict within 3 s -> TOOFAST" "$(ms inloop t7)" TOOFAST; ms stop t7 >/dev/null
# churn white-box: a 2-member session (sh + sleep) counted exactly while short processes come and go outside it
setsid sh -c 'echo $$ > "$1/dry.churn.pid"; sleep 40 & wait' _ "$W" > /dev/null 2>&1 < /dev/null &
i=0; while [ ! -s "$W/dry.churn.pid" ] && [ $i -lt 20 ]; do sleep 0.1; i=$((i + 1)); done
( for _ in $(seq 1 400); do /bin/true & done; wait ) & cp=$!
bad=0; for _ in 1 2 3 4 5 6 7 8 9 10; do r=$(ms scan churn); [ "$r" = "MEMBERS 2" ] || { bad=1; echo "     scan said [$r]"; }; done
wait $cp; want "scan under churn: MEMBERS 2 on all 10 scans" "$bad" 0
kill -- "-$(cat "$W/dry.churn.pid")" 2>/dev/null
# a comm with ") " inside: fields from the LAST ") "
FP=$T/fakeproc; mkdir -p "$FP/self" "$FP/101" "$FP/102"; echo '1 (x) S 0 1 1' > "$FP/self/stat"
echo '101 (a) b) S 1 101 777 0' > "$FP/101/stat"; echo '102 (ok) S 101 101 777 0' > "$FP/102/stat"; echo 777 > "$W/dry.fake.pid"
want "scan: a comm with ') ' parsed from the last ') '" "$(PRM_PROC=$FP ms scan fake)" 'MEMBERS 2'
rm -rf "$FP/self"; want "scan: no /proc/self -> INVALID" "$(PRM_PROC=$FP ms scan fake)" 'MEMBERS INVALID'
# precond
: > "$R/opt/batdata/state/autocommit-hold-once"; want "precond: hold-once named" "$(ms precond)" '*hold-once*'; rm -f "$R/opt/batdata/state/autocommit-hold-once"
mkdir -p "$T/fake"; printf '#!/bin/sh\nsleep 30\n' > "$T/fake/batman-autocommit"; sh "$T/fake/batman-autocommit" run > /dev/null 2>&1 & ap=$!; sleep 0.5
want "precond: a live batman-autocommit run named" "$(ms precond)" '*acrun*'
pkill -P $ap 2>/dev/null; kill $ap 2>/dev/null
want "precond: nothing -> empty" "$(ms precond)" ''
# restore: a run-dir file the arm made goes, the snapshot comes back
echo 'x' > "$R/run/autocommit.why"; echo "$(cat /proc/sys/kernel/random/boot_id) 99zz claimed unclaimed 1 0" > "$R/opt/batdata/state/prov-state"
o=$(ms restore); want "restore: RESTORED-SAME" "$o" 'RESTORED-SAME*'
want "restore: the arm's autocommit.why removed" "$(ls "$R/run")" ''
want "restore: prov-state back" "$(cut -d' ' -f2- "$R/opt/batdata/state/prov-state")" 'helper claimed member 1 radio'
echo "MISC-DRY cases=$n fails=$f"; [ "$n" -gt 0 ] && [ "$f" = 0 ]

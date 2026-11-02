#!/bin/sh
# scripts/node/prov-misc-254.sh — #254 prov-misc-254 dry-run arms on the node (docs/design/254-h23-harness.md §17.3,
# §19.1, §20.1, §21.3, §22.3, §23.3). Pushed into the unit's W dir (/tmp/run/batman-dv/wbox/<run>, root 0700) and run as
# root from there; it keeps its files next to itself. busybox ash. No `pgrep -f` (it matches its own command line, §19.1):
# processes are found by scanning /proc.
#   precond                 prints what forbids a dry run: sysupgrade-running / fw-override / hold-flag / hold-once /
#                           acrun (a batman-autocommit run alive); nothing = ok
#   save                    snapshot (§19.1 / §20.1): p6 prov-state, ota-armed.mesh; run dir autocommit.{wd,decided,why,
#                           hold-consumed,hold-discarded,ctl.dry}, autocommit-dryrun.log, canary-ok (presence + content);
#                           the helper pid; ota-trace line count
#   setps this|other <writer> <verdict> <mesh_expect>   white-box prov-state: fields 3 and 5 copied from the snapshot
#   setarm ab|other|none [<mode>]   white-box ota-armed.mesh "<boot8> <active slot> <mode>" (ab = the arm boot: the
#                           second-to-last boot-reasons line, the rule autocommit reads); none = removed
#   start <tag>             hold-consumed made if absent (the revert=0 path: no watchdog); dry.<tag>.sh staged (never
#                           rewritten) writes its pid atomically then execs the DRYRUN + FORCE_TRIAL + TIMEOUT=1 run;
#                           started with setsid. Within 2 s: dry.<tag>.pid numeric AND (its stat's session = its pid OR
#                           its stdout has a line) -> STARTED pid=<p> present=sid|out; else INVALID <why>
#   scan <tag>              MEMBERS <n> of the dry run's session (stat field 6, parsed after the last ") "); an
#                           unreadable /proc/self/stat or no readable entry -> INVALID
#   inloop <tag>            arm a (§19.1 / §22.3): node-side, the "gate until" line, then >= 3 s without the verdict line
#                           -> INLOOP (written to arm-a.<tag>.verdict); the verdict line within 3 s -> TOOFAST; no gate
#                           line within 30 s -> NOGATE
#   judge <tag> <cap s>     until the verdict line or <cap> s from the start; then the session must be empty within
#                           15 s (else TERM, 5 s, KILL the session -> INVALID). Checks "hold present — this trial will not
#                           be reverted" comes BEFORE "gate until". Prints JUDGE <ok|INVALID why> del=<node s, start to the
#                           verdict line> then the stdout.
#   stop <tag>              any member left: TERM, 5 s, KILL the session (its leader's cmdline must still be this dry run);
#                           removes the hold-consumed this arm made. STOPPED | KILLED <n>
#   restore                 put the snapshot back and compare; RESTORED-SAME | RESTORED-DIFF <what>; HELPER-SAME|CHANGED;
#                           TRACE-ADDED <n>
# PRM_ROOT / PRM_PROC (tests only, never on a node): prefix the node paths / /proc for the session scan.
set -u
W=$(cd "$(dirname "$0")" && pwd); R=${PRM_ROOT:-}; ST=$R/opt/batdata/state; LG=$R/opt/batdata/log; P=${PRM_PROC:-/proc}
. "$R/usr/lib/batman/rundir.sh" || { echo "FAIL no rundir.sh"; exit 1; }
RDF="autocommit.wd autocommit.decided autocommit.why autocommit.hold-consumed autocommit.hold-discarded autocommit.ctl.dry autocommit-dryrun.log canary-ok"
up(){ cut -d. -f1 /proc/uptime; }
cs(){ u=$(cut -d' ' -f1 /proc/uptime); echo "${u%.*}${u#*.}"; }   # uptime in 1/100 s (two decimals in /proc/uptime)
nap(){ sleep 0.1 2>/dev/null || sleep 1; }                       # a busybox without fractional sleep: 1 s steps
put(){ umask 077; printf '%s\n' "$2" > "$1.dv" && chmod 600 "$1.dv" && mv "$1.dv" "$1"; }
# members <sid>: processes whose session (stat field 6) is <sid>; INVALID when /proc cannot be read (§21.3)
members(){
	[ -r "$P/self/stat" ] || { echo INVALID; return; }
	m=0; rd=0
	for s in "$P"/[0-9]*/stat; do
		l=$(cat "$s" 2>/dev/null) || continue; rd=$((rd + 1))
		r=${l##*) }; set -- $r; [ "${4:-x}" = "$sid" ] && m=$((m + 1))   # after "comm) ": state ppid pgrp session
	done
	[ "$rd" -gt 0 ] && echo "$m" || echo INVALID
}
cmdscan(){ for c in /proc/[0-9]*/cmdline; do p=${c%/cmdline}; p=${p##*/}; [ "$p" = $$ ] && continue; tr '\0' ' ' 2>/dev/null < "$c" | grep -q -- "$1" && echo "$p"; done; }
snapls(){ for f in $RDF; do if [ -e "$RUNDIR/$f" ]; then echo "$f $(find "$RUNDIR/$f" -type f -exec cat {} + 2>/dev/null | cksum)"; else echo "$f absent"; fi; done
	for f in prov-state ota-armed.mesh; do [ -e "$ST/$f" ] && echo "$f $(cksum < "$ST/$f")" || echo "$f absent"; done; }
case "${1:-}" in
precond)
	[ -n "$(cmdscan '/sbin/sysupgrade')" ] && echo sysupgrade-running
	[ -e "$RUNDIR/batman-fw-override" ] && echo fw-override
	[ -e "$ST/autocommit-hold-commit" ] && echo hold-flag
	[ -e "$ST/autocommit-hold-once" ] && echo hold-once
	[ -n "$(cmdscan 'batman-autocommit run')" ] && echo "acrun $(cmdscan 'batman-autocommit run' | tr '\n' ' ')"
	exit 0 ;;
save)
	rm -rf "$W/snap"; mkdir -p "$W/snap/rd"
	cp -p "$ST/prov-state" "$W/snap/prov-state" || { echo "FAIL no prov-state"; exit 1; }
	[ -e "$ST/ota-armed.mesh" ] && cp -p "$ST/ota-armed.mesh" "$W/snap/ota-armed.mesh"
	for f in $RDF; do [ -e "$RUNDIR/$f" ] && cp -a "$RUNDIR/$f" "$W/snap/rd/$f"; done
	snapls > "$W/snap/list"
	pidof batman-provhelper > "$W/snap/helper"; wc -l < "$LG/ota-trace.log" > "$W/snap/trace"
	echo "SAVED ps=[$(cut -d' ' -f2- "$W/snap/prov-state")] arm=[$(cat "$W/snap/ota-armed.mesh" 2>/dev/null)] rd=[$(ls "$W/snap/rd" | tr '\n' ' ')] helper=$(cat "$W/snap/helper")" ;;
setps)
	b=$(cat /proc/sys/kernel/random/boot_id); [ "$2" = other ] && b=00000000-dead-beef-0000-$(head -c 6 /dev/urandom | hexdump -v -e '1/1 "%02x"')
	set -- "$b" "$3" "$(cut -d' ' -f3 "$W/snap/prov-state")" "$4" "$(cut -d' ' -f5 "$W/snap/prov-state")" "$5"
	put "$ST/prov-state" "$*"; echo "PS $(cut -d' ' -f2- "$ST/prov-state")" ;;
setarm)
	case "$2" in
		none) rm -f "$ST/ota-armed.mesh"; echo "ARM none"; exit 0 ;;
		ab) b=$(tail -n 2 "$LG/boot-reasons.log" | head -n 1 | sed -n 's/.* boot_id=\([0-9a-f]*\).*/\1/p') ;;
		other) b=$(head -c 4 /dev/urandom | hexdump -v -e '1/1 "%02x"') ;;
		*) echo "FAIL setarm $2"; exit 1 ;;
	esac
	put "$ST/ota-armed.mesh" "$b $(batman-slot active) $3"; echo "ARM $(cat "$ST/ota-armed.mesh")" ;;
start)
	t=$2; rm -f "$W/dry.$t" "$W/dry.$t.pid" "$W/dry.$t.pid.tmp" "$W/arm-a.$t.verdict" "$W/hc.$t"
	[ -e "$RUNDIR/autocommit.hold-consumed" ] || { : > "$RUNDIR/autocommit.hold-consumed" && echo made > "$W/hc.$t"; }
	# staged once, never rewritten while it runs; D is written in as an absolute path (§23.3)
	printf '#!/bin/sh\necho $$ > "%s/dry.%s.pid.tmp" && mv "%s/dry.%s.pid.tmp" "%s/dry.%s.pid"\nexec env AUTOCOMMIT_DRYRUN=1 AUTOCOMMIT_FORCE_TRIAL=1 AUTOCOMMIT_TIMEOUT=1 batman-autocommit run\n' "$W" "$t" "$W" "$t" "$W" "$t" > "$W/dry.$t.sh"
	up > "$W/t0.$t"
	setsid sh "$W/dry.$t.sh" > "$W/dry.$t" 2>&1 < /dev/null &
	# within 2 s: the pid file, then the session (immediately after setsid a read can still show the launcher's, §22.3)
	c0=$(cs); pid=""; present=""
	while [ $(( $(cs) - c0 )) -lt 200 ]; do
		[ -z "$pid" ] && { p=$(cat "$W/dry.$t.pid" 2>/dev/null); case "$p" in ''|*[!0-9]*) ;; *) pid=$p ;; esac; }
		if [ -n "$pid" ]; then
			l=$(cat "/proc/$pid/stat" 2>/dev/null); r=${l##*) }; set -- $r
			[ "${4:-}" = "$pid" ] && { present=sid; break; }
			grep -q 'batman-autocommit' "$W/dry.$t" 2>/dev/null && { present=out; break; }
		fi
		nap
	done
	[ -n "$pid" ] || { echo "INVALID no numeric dry.$t.pid within 2 s"; exit 0; }
	[ -n "$present" ] || { echo "INVALID dry run $pid neither a session leader nor any output within 2 s"; exit 0; }
	echo "STARTED pid=$pid present=$present" ;;
scan)
	sid=$(cat "$W/dry.$2.pid" 2>/dev/null); [ -n "$sid" ] || { echo "INVALID no pid"; exit 0; }
	echo "MEMBERS $(members)" ;;
inloop)
	t=$2; t0=$(cat "$W/t0.$t")
	while ! grep -q 'gate until uptime' "$W/dry.$t" 2>/dev/null; do [ $(( $(up) - t0 )) -ge 30 ] && { echo NOGATE > "$W/arm-a.$t.verdict"; echo NOGATE; exit 0; }; nap; done
	sleep 3
	if grep -q 'mesh join required:' "$W/dry.$t"; then v=TOOFAST; else v=INLOOP; fi
	echo "$v" > "$W/arm-a.$t.verdict"; echo "$v" ;;
judge)
	t=$2; cap=$3; t0=$(cat "$W/t0.$t"); sid=$(cat "$W/dry.$t.pid" 2>/dev/null); v=ok; del=""
	while :; do
		grep -q 'mesh join required:' "$W/dry.$t" 2>/dev/null && { del=$(( $(up) - t0 )); break; }
		[ $(( $(up) - t0 )) -ge "$cap" ] && { v="INVALID no verdict line within the ${cap}s cap"; break; }
		sleep 1
	done
	if [ -n "$del" ]; then
		i=0; while [ $i -lt 15 ]; do n=$(members); [ "$n" = 0 ] && break; [ "$n" = INVALID ] && { v="INVALID /proc unreadable"; break; }; sleep 1; i=$((i + 1)); done
		[ "$n" = 0 ] || { [ "$v" = ok ] && v="INVALID the session still had $n member(s) 15 s after the verdict line"; }
	fi
	hp=$(grep -n 'hold present — this trial will not be reverted$' "$W/dry.$t" | head -1 | cut -d: -f1)
	gl=$(grep -n 'gate until uptime' "$W/dry.$t" | head -1 | cut -d: -f1)
	if [ "$v" = ok ]; then
		[ -n "$hp" ] || v="INVALID no 'hold present — this trial will not be reverted' line (the revert=0 path was not taken)"
		[ "$v" = ok ] && [ -n "$gl" ] && [ "$hp" -gt "$gl" ] && v="INVALID 'hold present' after 'gate until'"
	fi
	echo "JUDGE $v del=${del:-none}"; cat "$W/dry.$t" ;;
stop)
	t=$2; sid=$(cat "$W/dry.$t.pid" 2>/dev/null); k=0
	if [ -n "$sid" ] && n=$(members) && [ "$n" != 0 ] && [ "$n" != INVALID ]; then
		# the leader must still be this dry run (sid reuse): its cmdline names the run, or it is gone and members remain
		lc=$(tr '\0' ' ' 2>/dev/null < "/proc/$sid/cmdline")
		case "$lc" in ''|*batman-autocommit*|*"dry.$t.sh"*) kill -TERM "-$sid" 2>/dev/null; sleep 5; kill -KILL "-$sid" 2>/dev/null; k=$n ;;
			*) echo "FAIL session $sid leader is [$lc] — not this dry run, not killed"; exit 1 ;; esac
	fi
	[ -f "$W/hc.$t" ] && rm -f "$RUNDIR/autocommit.hold-consumed" "$W/hc.$t"
	[ "$k" = 0 ] && echo STOPPED || echo "KILLED $k" ;;
restore)
	[ -f "$W/snap/prov-state" ] || { echo "FAIL no snapshot"; exit 1; }
	cp -p "$W/snap/prov-state" "$ST/prov-state.dv" && mv "$ST/prov-state.dv" "$ST/prov-state"
	if [ -f "$W/snap/ota-armed.mesh" ]; then cp -p "$W/snap/ota-armed.mesh" "$ST/ota-armed.mesh.dv" && mv "$ST/ota-armed.mesh.dv" "$ST/ota-armed.mesh"; else rm -f "$ST/ota-armed.mesh"; fi
	for f in $RDF; do rm -rf "${RUNDIR:?}/$f"; [ -e "$W/snap/rd/$f" ] && cp -a "$W/snap/rd/$f" "$RUNDIR/$f"; done
	sync
	snapls > "$W/snap/now"
	if cmp -s "$W/snap/list" "$W/snap/now"; then echo RESTORED-SAME; else echo "RESTORED-DIFF $(diff "$W/snap/list" "$W/snap/now" | grep '^[<>]' | tr '\n' ' ')"; fi
	[ "$(pidof batman-provhelper)" = "$(cat "$W/snap/helper")" ] && echo HELPER-SAME || echo "HELPER-CHANGED $(cat "$W/snap/helper") -> $(pidof batman-provhelper)"
	echo "TRACE-ADDED $(( $(wc -l < "$LG/ota-trace.log") - $(cat "$W/snap/trace") ))" ;;
*) echo "usage: prov-misc-254.sh precond|save|setps|setarm|start|scan|inloop|judge|stop|restore"; exit 2 ;;
esac

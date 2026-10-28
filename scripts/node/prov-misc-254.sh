#!/bin/sh
# scripts/node/prov-misc-254.sh — #254 prov-misc-254 dry-run arms on the node (docs/design/254-h23-harness.md §17.3).
# Pushed into the unit's W dir (/tmp/run/batman-dv/wbox/<run>, root 0700) and run as root from there; it keeps its
# files next to itself. busybox ash.
#   save                    snapshot p6 prov-state / ota-armed.mesh, which run-dir autocommit files exist, helper pid,
#                           ota-trace line count
#   setps this|other <writer> <verdict> <mesh_expect>   white-box prov-state: fields 3 and 5 copied from the snapshot
#   setarm ab|other|none [<mode>]   white-box ota-armed.mesh "<boot8> <active slot> <mode>" (ab = the arm boot: the
#                           second-to-last boot-reasons line, the rule autocommit reads); none = removed
#   start <tag>             setsid dry run (DRYRUN + FORCE_TRIAL, deadline uptime + 600), stdout to dry.<tag>; prints pgid
#   insleep <tag>           wait (<= 30 s) until the dry run's process group has a `sleep` child (it is in a wait loop)
#   wait <tag> <secs>       until "mesh join required:" is printed or <secs>; prints ELAPSED <s> then the stdout
#   stop <tag>              TERM the process group; any batman-autocommit run left -> LEFTOVER (+ KILL)
#   restore                 put the snapshot back; prints HELPER-SAME|HELPER-CHANGED and TRACE-ADDED <n>
set -u
W=$(cd "$(dirname "$0")" && pwd); ST=/opt/batdata/state
. /usr/lib/batman/rundir.sh || { echo "FAIL no rundir.sh"; exit 1; }
up(){ cut -d. -f1 /proc/uptime; }
put(){ umask 077; printf '%s\n' "$2" > "$1.dv" && chmod 600 "$1.dv" && mv "$1.dv" "$1"; }
case "${1:-}" in
save)
	cp -p "$ST/prov-state" "$W/ps.snap" || { echo "FAIL no prov-state"; exit 1; }
	if [ -e "$ST/ota-armed.mesh" ]; then cp -p "$ST/ota-armed.mesh" "$W/arm.snap"; else rm -f "$W/arm.snap"; fi
	: > "$W/rd.snap"; for f in autocommit.wd autocommit.decided; do [ -e "$RUNDIR/$f" ] && echo "$f" >> "$W/rd.snap"; done
	pidof batman-provhelper > "$W/hp.snap"; wc -l < /opt/batdata/log/ota-trace.log > "$W/tr.snap"
	echo "SAVED ps=[$(cut -d' ' -f2- "$W/ps.snap")] arm=[$(cat "$W/arm.snap" 2>/dev/null)] rd=[$(tr '\n' ' ' < "$W/rd.snap")] helper=$(cat "$W/hp.snap")" ;;
setps)
	b=$(cat /proc/sys/kernel/random/boot_id); [ "$2" = other ] && b=00000000-dead-beef-0000-$(head -c 6 /dev/urandom | hexdump -v -e '1/1 "%02x"')
	set -- "$b" "$3" "$(cut -d' ' -f3 "$W/ps.snap")" "$4" "$(cut -d' ' -f5 "$W/ps.snap")" "$5"
	put "$ST/prov-state" "$*"; echo "PS $(cut -d' ' -f2- "$ST/prov-state")" ;;
setarm)
	case "$2" in
		none) rm -f "$ST/ota-armed.mesh"; echo "ARM none"; exit 0 ;;
		ab) b=$(tail -n 2 /opt/batdata/log/boot-reasons.log | head -n 1 | sed -n 's/.* boot_id=\([0-9a-f]*\).*/\1/p') ;;
		other) b=$(head -c 4 /dev/urandom | hexdump -v -e '1/1 "%02x"') ;;
		*) echo "FAIL setarm $2"; exit 1 ;;
	esac
	put "$ST/ota-armed.mesh" "$b $(batman-slot active) $3"; echo "ARM $(cat "$ST/ota-armed.mesh")" ;;
start)
	t=$2; rm -f "$W/dry.$t" "$W/pg.$t"; up > "$W/t0.$t"; u=$(up)
	setsid sh -c "echo \$\$ > '$W/pg.$t'; exec env AUTOCOMMIT_DRYRUN=1 AUTOCOMMIT_FORCE_TRIAL=1 AUTOCOMMIT_TIMEOUT=$((u + 600)) batman-autocommit run > '$W/dry.$t' 2>&1" </dev/null >/dev/null 2>&1 &
	i=0; while [ ! -s "$W/pg.$t" ] && [ $i -lt 10 ]; do sleep 1; i=$((i + 1)); done
	[ -s "$W/pg.$t" ] && echo "PGID $(cat "$W/pg.$t")" || { echo "FAIL dry run did not start"; exit 1; } ;;
insleep)
	pg=$(cat "$W/pg.$2"); i=0
	while [ $i -lt 30 ]; do
		for d in /proc/[0-9]*; do s=$(cat "$d/stat" 2>/dev/null) || continue
			case "$s" in *"(sleep) "*) set -- ${s#*) }; [ "$3" = "$pg" ] && { echo INSLEEP; exit 0; } ;; esac; done
		sleep 1; i=$((i + 1))
	done; echo NOSLEEP; exit 1 ;;
wait)
	t=$2; t0=$(cat "$W/t0.$t")
	while :; do grep -q "mesh join required:" "$W/dry.$t" 2>/dev/null && break; [ $(( $(up) - t0 )) -ge "$3" ] && break; sleep 1; done
	echo "ELAPSED $(( $(up) - t0 ))"; cat "$W/dry.$t" 2>/dev/null ;;
stop)
	pg=$(cat "$W/pg.$2" 2>/dev/null); [ -n "$pg" ] && kill -TERM "-$pg" 2>/dev/null; sleep 2
	if pgrep -f "batman-autocommit run" >/dev/null; then echo "LEFTOVER $(pgrep -f 'batman-autocommit run' | tr '\n' ' ')"; [ -n "$pg" ] && kill -KILL "-$pg" 2>/dev/null; pkill -KILL -f "batman-autocommit run"; else echo STOPPED; fi ;;
restore)
	[ -f "$W/ps.snap" ] || { echo "FAIL no snapshot"; exit 1; }
	cp -p "$W/ps.snap" "$ST/prov-state.dv" && mv "$ST/prov-state.dv" "$ST/prov-state"
	if [ -f "$W/arm.snap" ]; then cp -p "$W/arm.snap" "$ST/ota-armed.mesh.dv" && mv "$ST/ota-armed.mesh.dv" "$ST/ota-armed.mesh"; else rm -f "$ST/ota-armed.mesh"; fi
	for f in autocommit.wd autocommit.decided; do grep -qx "$f" "$W/rd.snap" || rm -rf "${RUNDIR:?}/$f"; done
	sync
	[ "$(pidof batman-provhelper)" = "$(cat "$W/hp.snap")" ] && echo HELPER-SAME || echo "HELPER-CHANGED $(cat "$W/hp.snap") -> $(pidof batman-provhelper)"
	echo "TRACE-ADDED $(( $(wc -l < /opt/batdata/log/ota-trace.log) - $(cat "$W/tr.snap") ))" ;;
*) echo "usage: prov-misc-254.sh save|setps|setarm|start|insleep|wait|stop|restore"; exit 2 ;;
esac

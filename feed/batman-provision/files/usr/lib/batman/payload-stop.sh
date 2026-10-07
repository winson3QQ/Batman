# payload-stop.sh — graceful, tiered, recorded stop of a payload tenant (#274, docs/design/274-payload-converge.md §8).
#
# Sourced by the per-tenant guardian (stop_service, K09) and by /etc/init.d/batman-prestop-payload (K08).
# A clean shutdown gives every K script 15 s (then TERM, +10 s, KILL), so the stop is split:
#   K08 prestop   pstop_early <t>  set .stopping, kill an in-flight payload-run tree, stop every tier but the
#                                  last (clients first), each tier in parallel, -t 5
#   K09 guardian  pstop_final <t>  (does pstop_early itself if K08 did not run, e.g. an operator `stop`),
#                                  stop the final tier (the stateful services), -t 10, sweep, record
# Tiers come from `STOPTIER <n>` in the manifest (profile.yaml lifecycle.stop_tier); a container without one
# is in the final tier. `docker stop` (never rm) sets docker's manual-stop flag, so with unless-stopped
# dockerd does not revive the stack at the next boot — the guardian's start mode does, ordered and gated.
# Record: one line per stop in $LOG/payload-stop.log and in syslog (so the shutdown_*.log that K10batdata-mount
# captures has it): elapsed, how many were running, every container's ExitCode (137/255 = SIGKILLed).
#
# shellcheck shell=sh

PSTOP_APPS="${APPS_DIR:-/opt/batdata/apps}"
PSTOP_RUN="${PAYLOAD_RUNDIR:-/tmp}"
PSTOP_LOG="${PAYLOAD_STOP_LOG:-/opt/batdata/log/payload-stop.log}"

pstop_up(){ cut -d' ' -f1 /proc/uptime; }
pstop_manifest(){ ls "$PSTOP_APPS/$1"/*.manifest 2>/dev/null | head -1; }
# "name tier" per container in manifest order; no STOPTIER = 99 (final)
pstop_tiers(){ awk '$1=="CONTAINER"{if(n!="")print n, t; n=$2; t=99} $1=="STOPTIER"{t=$2+0} END{if(n!="")print n, t}' "$1"; }
pstop_tree(){ echo "$1"; for c in $(pgrep -P "$1" 2>/dev/null); do pstop_tree "$c"; done; }

# kill an in-flight payload-run of this tenant — only if it really holds the lock (#274 P2: a stale pid
# file / reused PID must never get an unrelated process killed)
pstop_kill(){
	t=$1; pidf="$PSTOP_RUN/batman-payload-$t.pid"; lock="$PSTOP_RUN/batman-payload-$t.lock"
	[ -f "$pidf" ] || return 0
	if ( exec 8>"$lock"; flock -n 8 ) 2>/dev/null; then rm -f "$pidf"; return 0; fi   # nobody holds it: stale
	pid=$(cat "$pidf" 2>/dev/null); case "$pid" in ''|*[!0-9]*) return 0 ;; esac
	tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null | grep -q "payload-run .*$t \?$" || return 0
	tree=$(pstop_tree "$pid")
	logger -t "batman-payload-$t" "stop: killing in-flight payload-run (pid $pid, tree:$(echo $tree))"
	# shellcheck disable=SC2086
	kill -TERM $tree 2>/dev/null
	# busybox sleep takes whole seconds only: one 1 s grace, then KILL what is left
	alive=""; for p in $tree; do [ -d "/proc/$p" ] && alive="$alive $p"; done
	if [ -n "$alive" ]; then
		sleep 1
		alive=""; for p in $tree; do [ -d "/proc/$p" ] && alive="$alive $p"; done
		# shellcheck disable=SC2086
		[ -n "$alive" ] && kill -KILL $alive 2>/dev/null
	fi
	return 0
}

# docker stop -t $2 (parallel) of the RUNNING containers among $3...
pstop_stop(){
	to=$1; shift; run=""
	for c in "$@"; do [ "$(docker inspect -f '{{.State.Running}}' "$c" 2>/dev/null)" = true ] && run="$run $c"; done
	[ -n "$run" ] || return 0
	# shellcheck disable=SC2086
	docker stop -t "$to" $run >/dev/null 2>&1
	return 0
}

pstop_early(){
	t=$1; st="$PSTOP_RUN/batman-payload-$t.stop0"
	: > "$PSTOP_RUN/batman-payload-$t.stopping"
	[ -f "$st" ] && return 0                          # already done (K08 ran, K09 calls again)
	pstop_kill "$t"
	m=$(pstop_manifest "$t"); [ -n "$m" ] || return 0
	docker info >/dev/null 2>&1 || { echo "$(pstop_up) 0 nodocker" > "$st"; return 0; }
	n=0; for c in $(awk '$1=="CONTAINER"{print $2}' "$m"); do
		[ "$(docker inspect -f '{{.State.Running}}' "$c" 2>/dev/null)" = true ] && n=$((n + 1))
	done
	echo "$(pstop_up) $n" > "$st"
	final=$(pstop_tiers "$m" | awk 'BEGIN{x=0} $2>x{x=$2} END{print x}')
	for tier in $(pstop_tiers "$m" | awk -v f="$final" '$2<f{print $2}' | sort -n -u); do
		# shellcheck disable=SC2046
		pstop_stop 5 $(pstop_tiers "$m" | awk -v k="$tier" '$2==k{print $1}')
	done
	return 0
}

pstop_final(){
	t=$1; st="$PSTOP_RUN/batman-payload-$t.stop0"
	pstop_early "$t"
	m=$(pstop_manifest "$t"); [ -n "$m" ] || return 0
	read -r t0 n rest < "$st" 2>/dev/null || { t0=$(pstop_up); n=0; rest=""; }
	[ "$rest" = nodocker ] && { rm -f "$st"; return 0; }
	final=$(pstop_tiers "$m" | awk 'BEGIN{x=0} $2>x{x=$2} END{print x}')
	# shellcheck disable=SC2046
	pstop_stop 10 $(pstop_tiers "$m" | awk -v f="$final" '$2==f{print $1}')
	# sweep: anything an in-flight request started after its tier was stopped
	# shellcheck disable=SC2046
	pstop_stop 1 $(awk '$1=="CONTAINER"{print $2}' "$m")
	# test seam (daily-validation cleanstop-274 negative control DV_TEST_274_RMSTOP): behave like the
	# rejected feat/264 stop once — remove the containers — so the "not recreated" check must FAIL
	if [ -f /opt/batdata/state/fault.274-rmstop-once ]; then
		rm -f /opt/batdata/state/fault.274-rmstop-once
		# shellcheck disable=SC2046
		docker rm $(awk '$1=="CONTAINER"{print $2}' "$m") >/dev/null 2>&1
		logger -t "batman-payload-$t" "stop: TEST fault.274-rmstop-once — containers removed"
	fi
	rm -f "$st"
	[ "$n" -gt 0 ] 2>/dev/null || return 0             # nothing was running: no record (double stop, legacy K10)
	# shellcheck disable=SC2046
	codes=$(docker inspect -f '{{.Name}}={{.State.ExitCode}}' $(awk '$1=="CONTAINER"{print $2}' "$m") 2>/dev/null | sed 's#^/##' | tr '\n' ' ')
	el=$(awk -v a="$t0" -v b="$(pstop_up)" 'BEGIN{printf "%.1f", b-a}')
	line="boot=$(cut -c1-8 /proc/sys/kernel/random/boot_id) tenant=$t elapsed=${el}s running_at_start=$n exit: $codes"
	logger -t "batman-payload-$t" "stop: $line"
	mount | grep -q " /opt/batdata " && { mkdir -p "${PSTOP_LOG%/*}"; echo "$(date +%Y%m%d-%H%M%S) $line" >> "$PSTOP_LOG"; }
	return 0
}

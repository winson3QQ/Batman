#!/bin/sh
# payload-guardian-run.sh <tenant> — the supervised body of a payload tenant's guardian (#156/#167/#274).
#
# Run by procd (respawn) from /usr/lib/batman/payload-guardian.sh's start_service. Design:
# docs/design/274-payload-converge.md §12 (v8.2). The guardian is the ONLY component that starts or restarts a
# tenant container (every container is created `--restart no`):
#   1. wait for the docker API; arbiter; start-up converge (`payload-run --converge`: ordered start, or rebuild
#      when the config changed);
#   2. every 5 s: one `docker ps` liveness poll. A tenant container that exited is restarted on whatever
#      config it carries (`payload-run --restart-exited`: never a rebuild, no scripts), with backoff
#      0/10/20/40/60 s; a missing one makes the guardian exit for respawn, so its start-up converge rebuilds it;
#   3. every 30 s: the verdict (drift.json, read by batman-autocommit and halow-status) and the host alarm.
# Every restart is a line in the per-boot ledger in the root-only run dir; any line in the last 600 s keeps the
# tenant DRIFT, so a crash during an OTA trial reverts it (user decision, §12.13).
# Root never executes a p6 copy of a golden tenant's script: reconcile-resources.sh, verify-profile-*.sh (and
# the env files they source, via HERE) and *.fw4.uci run from the read-only image (§12 D7-7).
#
# shellcheck shell=sh

T="${1:?usage: payload-guardian-run.sh <tenant>}"
APPS_DIR="${APPS_DIR:-/opt/batdata/apps}"
DIR="$APPS_DIR/$T"
# shellcheck source=/dev/null
[ -r /usr/lib/batman/rundir.sh ] && . /usr/lib/batman/rundir.sh
R="${PAYLOAD_RUNDIR:-${RUNDIR:-/nonexistent/batman-rundir}}"
# shellcheck source=/dev/null
. "${PAYLOAD_LIB:-/usr/lib/batman/payload-lib.sh}" || { echo "batman-payload[$T]: payload-lib.sh missing"; exit 1; }
GOLD="${PAYLOAD_GOLDEN_ROOT:-/usr/share/batman/payload-golden}/$T"; [ -d "$GOLD" ] || GOLD=""
XDIR=${GOLD:-$DIR}                        # where the tenant's scripts are executed from
PR="${PAYLOAD_RUN:-payload-run}"

DRIFT_FILE=$R/batman-payload-$T-drift.json
VERIFY_LOG=$R/batman-payload-$T-verify.log
LEDGER=$R/batman-payload-$T-restarts
UP=$R/batman-payload-$T.up
ALARM=$R/batman-payload-$T-host-alarm
STOPPING=$R/batman-payload-$T.stopping
SHUTDOWN=$R/batman-shutdown
POLL=${PAYLOAD_POLL:-5}; INTERVAL=${PAYLOAD_INTERVAL:-30}; WINDOW=600

UPF=${PAYLOAD_UPTIME_FILE:-/proc/uptime}  # test seam (scripts/test-payload-guardian.sh); procd sets no env
now(){ cut -d. -f1 "$UPF"; }
lg(){ echo "batman-payload[$T]: $*"; }
opf(){ type batman_opf >/dev/null 2>&1 && BATMAN_OPF_QUIET=1 batman_opf "$1"; }
halted(){ [ -e "$STOPPING" ] || [ -e "$SHUTDOWN" ]; }

# ---- ledger: "<uptime> <kind> <names…> [id= started=]"; "<uptime> cancel" voids the line before it ----
LEDGER_BAD=0; MEM_LAST=0; MEM_K=0
ledger_add(){   # $1 = kind, rest = names/fields. Appended BEFORE acting; a failed append is DRIFT (B-m2)
	k=$1; shift
	if echo "$(now) $k $*" >> "$LEDGER" 2>/dev/null; then :; else LEDGER_BAD=1; lg "ledger unwritable ($LEDGER)"; fi
}
# counted records (cancel removes the one before it); a malformed uptime counts as "now" (fail-closed)
ledger_times(){   # $1 = kind regexp; prints one uptime per counted record of those kinds
	[ -f "$LEDGER" ] || return 0
	awk -v kr="$1" -v nw="$(now)" '
		BEGIN { n = 0 }      # numeric from the start: t[""] is not t[0] (the first record was lost)
		$2=="cancel" { if (n>0) n--; next }
		{ u=($1 ~ /^[0-9]+$/) ? $1 : nw; t[n]=u; k[n]=$2; n++ }
		END { for (i=0;i<n;i++) if (k[i] ~ kr) print t[i] }' "$LEDGER"
}
recent_records(){ lo=$(( $(now) - WINDOW )); ledger_times '.' | awk -v lo="$lo" '$1>=lo' | wc -l; }
# backoff: attempts in the current episode (records < 600 s apart, the last < 600 s ago); attempt k+1 waits
# min(10·2^(k−1), 60) s after the k-th (0, 10, 20, 40, 60, 60, …)
restart_allowed(){
	nw=$(now)
	if [ "$LEDGER_BAD" = 1 ]; then last=$MEM_LAST; kk=$MEM_K
	else
		# shellcheck disable=SC2046  # "<last> <k>" split on purpose
		set -- $(ledger_times '^crash$' | awk -v nw="$nw" '
			{ if (n>0 && $1-p >= 600) n=0; p=$1; n++ }
			END { if (n>0 && nw-p < 600) print p, n; else print 0, 0 }')
		last=$1; kk=$2
	fi
	[ "$kk" -gt 0 ] || return 0
	[ "$((nw - last))" -ge 600 ] && return 0
	d=10; i=1; while [ "$i" -lt "$kk" ] && [ "$d" -lt 60 ]; do d=$((d * 2)); i=$((i + 1)); done
	[ "$d" -gt 60 ] && d=60
	[ "$((nw - last))" -ge "$d" ]
}

# ---- 1. docker API, manifest, arbiter, start-up converge ----
i=0; until docker info >/dev/null 2>&1; do
	i=$((i + 1)); [ "$i" -gt 45 ] && { lg "waiting for dockerd"; exit 1; }
	sleep 2
done
MANIFEST=$(ls "$DIR"/*.manifest 2>/dev/null | head -1)
NETALLOC=$(ls "$DIR"/*.net.alloc 2>/dev/null | head -1)
[ -n "$MANIFEST" ] || { lg "no manifest in $DIR"; exit 1; }
NAMES=$(awk '/^CONTAINER /{print $2}' "$MANIFEST")
NET=$(awk '$1=="NETWORK_NAME"{print $2; exit}' "$MANIFEST")
[ -n "$NAMES" ] || { lg "no CONTAINER in manifest"; exit 1; }
if [ -n "$NETALLOC" ] && command -v payload-arbiter >/dev/null 2>&1; then
	payload-arbiter "$NETALLOC" "$APPS_DIR" || { lg "arbiter REFUSED bring-up"; exit 1; }
fi
# #274 D7-7: no *.fw4.uci here any more (was payload-guardian.sh:72) — payload-run's start mode applies the
# image's copy; with policy `no` every boot's converge runs start mode, so a fresh slot still gets the rules.
RESPAWN=0; [ -e "$UP" ] && RESPAWN=1     # start_service removes .up: present = procd respawned us
CFG=$($PR --cfg-hash "$T" 2>/dev/null)
need=0; down0=""
for c in $NAMES; do
	s=$(docker inspect -f "{{.State.Status}} {{.State.Restarting}} {{index .Config.Labels \"batman.cfg\"}}" "$c" 2>/dev/null)
	[ -n "$CFG" ] && [ "$s" = "running false $CFG" ] || { need=1; case "$s" in running*) ;; *) down0="$down0 $c" ;; esac; }
done
if [ "$need" = 1 ]; then
	halted && { lg "tenant is being stopped / the node is shutting down — not converging"; exit 1; }
	[ "$RESPAWN" = 1 ] && [ -n "$down0" ] && ledger_add respawn $down0
	lg "converging the stack (container down or config fingerprint changed)"
	touch "$R/batman-payload-$T.converging"
	$PR --converge "$T"; prc=$?
	rm -f "$R/batman-payload-$T.converging"
	lg "converge done rc=$prc uptime=$(cut -d' ' -f1 /proc/uptime)"
	[ "$prc" = 4 ] && { lg "tenant is being stopped — not converging"; exit 1; }
fi
: > "$UP" 2>/dev/null

# ---- policy (D7-1): reset any restart policy but `no` on every tenant container; record it (and a
# RestartCount > 0) for current-config containers only, once per (container ID, StartedAt) ----
check_policy(){
	cfg=$1
	for id in $(docker ps -aq --filter "label=batman.tenant=$T" 2>/dev/null); do
		# shellcheck disable=SC2046  # five space-free fields, split on purpose
		set -- $(docker inspect -f '{{.Name}} {{.HostConfig.RestartPolicy.Name}} {{.RestartCount}} {{index .Config.Labels "batman.cfg"}} {{.State.StartedAt}}' "$id" 2>/dev/null)
		[ $# -ge 5 ] || continue
		p_n=${1#/}; p_pol=$2; p_rc=$3; p_lab=$4; p_st=$5
		if [ "$p_pol" != no ]; then
			docker update --restart no "$id" >/dev/null 2>&1 && lg "restart policy of $p_n was $p_pol — reset to no"
		fi
		[ -n "$cfg" ] && [ "$p_lab" = "$cfg" ] || continue
		if [ "$p_pol" != no ] || [ "$p_rc" -gt 0 ] 2>/dev/null; then
			key="id=$(echo "$id" | cut -c1-12) started=$p_st"
			grep -q " policy .*$key" "$LEDGER" 2>/dev/null || { ledger_add policy "$p_n" "$key"; lg "restart: policy $p_n (policy=$p_pol restarts=$p_rc)"; }
		fi
	done
}
check_policy "$CFG"

# ---- 2./3. the loop ----
down=0; last_tick=0; BYPASS=""; MISSING=""; NOTRUN=""; ALARM_PREV=""
while :; do
	ps_=$(docker ps -a --filter "label=batman.tenant=$T" --format '{{.Names}} {{.State}}' 2>/dev/null); prc_=$?
	if [ "$prc_" != 0 ] || ! docker info >/dev/null 2>&1; then
		down=$((down + POLL)); [ "$down" -gt 120 ] && { lg "docker API down > 120 s — exiting for respawn"; exit 1; }
		sleep "$POLL"; continue
	fi
	down=0; ex=""; BYPASS=""; MISSING=""; NOTRUN=""
	for c in $NAMES; do
		cst=$(echo "$ps_" | awk -v c="$c" '$1==c{print $2; exit}')
		case "$cst" in
			running) ;;
			exited|created|dead) ex="$ex $c"; NOTRUN="$NOTRUN $c" ;;
			"") if docker inspect "$c" >/dev/null 2>&1; then BYPASS="$BYPASS $c"; else MISSING="$MISSING $c"; fi
			    NOTRUN="$NOTRUN $c" ;;
			*) NOTRUN="$NOTRUN $c" ;;
		esac
	done
	if ! halted; then
		if [ -n "$MISSING" ]; then
			lo=$(( $(now) - 600 ))
			if [ "$(ledger_times '^missing$' | awk -v lo="$lo" '$1>=lo' | wc -l)" = 0 ]; then
				ledger_add missing $MISSING
				lg "restart: missing$MISSING — exiting for respawn (the start-up converge rebuilds)"
				exit 1
			fi
		fi
		if [ -n "$ex" ] && restart_allowed; then
			ledger_add crash $ex
			MEM_K=$((MEM_K + 1)); MEM_LAST=$(now)
			lg "restart: crash$ex"
			PAYLOAD_LOCK_WAIT=5 $PR --restart-exited "$T"; rrc=$?
			case "$rrc" in
				0) ;;
				4|5) echo "$(now) cancel" >> "$LEDGER" 2>/dev/null; lg "restart: rc=$rrc (stopping or lock busy) — not counted" ;;
				*) lg "restart: rc=$rrc" ;;
			esac
		fi
	fi
	nw=$(now)
	if [ "$((nw - last_tick))" -lt "$INTERVAL" ]; then sleep "$POLL"; continue; fi
	last_tick=$nw

	# ---- the verdict (tick) ----
	WINDOW=600; opf "$R/fault.274-window60" && { WINDOW=60; lg "TEST fault.274-window60: ledger window 60 s"; }
	[ -x "$XDIR/reconcile-resources.sh" ] && sh "$XDIR/reconcile-resources.sh" >"$R/batman-payload-$T-resources.log" 2>&1 || true
	st=OK; : > "$VERIFY_LOG"; alarm=""
	for c in $NOTRUN; do st=DRIFT; echo "container $c NOT running" >>"$VERIFY_LOG"; done
	for c in $BYPASS; do st=DRIFT; echo "container $c is not ours (no batman.tenant=$T label) — never started by the guardian" >>"$VERIFY_LOG"; done
	for c in $MISSING; do st=DRIFT; echo "container $c missing" >>"$VERIFY_LOG"; done
	[ "$LEDGER_BAD" = 1 ] && { st=DRIFT; echo "ledger unwritable ($LEDGER)" >>"$VERIFY_LOG"; }
	n=$(recent_records)
	[ "$n" -gt 0 ] && { st=DRIFT; echo "the guardian restarted a container $n time(s) in the last ${WINDOW} s:" >>"$VERIFY_LOG"; tail -5 "$LEDGER" >>"$VERIFY_LOG" 2>/dev/null; }
	CFG=$($PR --cfg-hash "$T" 2>/dev/null)
	check_policy "$CFG"
	for c in $NAMES; do
		lab=$(docker inspect -f '{{index .Config.Labels "batman.cfg"}}' "$c" 2>/dev/null) || continue
		[ -n "$CFG" ] && [ -n "$lab" ] && [ "$lab" != "$CFG" ] && { st=DRIFT; echo "container $c config changed since start — restart the guardian to apply" >>"$VERIFY_LOG"; }
		p=$(pl_container_problems "$c" "$DIR" "$NET")
		[ -n "$p" ] && [ "$p" != gone ] && { st=DRIFT; echo "container $c is not on the allowlist: $(echo "$p" | tr '\n' ';')" >>"$VERIFY_LOG"; }
	done
	# golden tenant: p6 copies must equal the image (the boot refresh made them equal); extras are inert
	if [ -n "$GOLD" ]; then
		for g in "$GOLD"/*; do
			[ -f "$g" ] || continue; b=${g##*/}
			case "$b" in *.manifest) continue ;; esac     # read from p6 on purpose; the cfg hash covers it
			cmp -s "$g" "$DIR/$b" 2>/dev/null || { st=DRIFT; echo "p6 file $b differs from the image" >>"$VERIFY_LOG"; }
		done
		for f in "$DIR"/*; do
			[ -f "$f" ] || continue; b=${f##*/}
			[ -f "$GOLD/$b" ] && continue
			case "$b" in verify-profile.sh) continue ;; esac   # an older image's wrapper needs it on p6 (E38)
			if opf "$R/fault.274-leftover-drift"; then st=DRIFT; echo "p6 file $b is not from the image (TEST fault.274-leftover-drift)" >>"$VERIFY_LOG"
			else alarm="${alarm}p6-file $DIR/$b is not from the image (never executed)
"; fi
		done
	else
		alarm="${alarm}tenant $T has no golden copy in the image — its scripts run from p6
"
	fi
	for vp in "$XDIR"/verify-profile-*.sh; do
		[ -f "$vp" ] || continue
		if sh "$vp" >>"$VERIFY_LOG" 2>&1; then :; else st=DRIFT; fi
	done
	# host alarm (D7-5): node-wide conditions an OTA cannot cause or fix — never in the verdict
	[ "$(docker info -f '{{.LiveRestoreEnabled}}' 2>/dev/null)" = true ] && alarm="${alarm}live-restore is on — an OTA would kill the tenant instead of stopping it
"
	tenants=" "; for d in "$APPS_DIR"/*/; do ls "$d"*.manifest >/dev/null 2>&1 && { t_=${d%/}; tenants="$tenants${t_##*/} "; }; done
	for line in $(docker ps -a --format '{{.ID}}:{{.Label "batman.tenant"}}' 2>/dev/null); do
		id=${line%%:*}; lt=${line#*:}
		case "$tenants" in *" $lt "*) [ -n "$lt" ] && continue ;; esac
		p=$(pl_container_problems "$id" "" "")
		[ -n "$p" ] && [ "$p" != gone ] && alarm="${alarm}foreign-container $(docker inspect -f '{{.Name}}' "$id" 2>/dev/null | tr -d /) ($id): $(echo "$p" | tr '\n' ';')
"
	done
	for f in "${APPS_DIR%/apps}"/deploy/*/*.init; do
		[ -f "$f" ] && alarm="${alarm}legacy init $f present (no longer installed)
"
	done
	printf '%s' "$alarm" > "$ALARM.tmp" 2>/dev/null && mv -f "$ALARM.tmp" "$ALARM" 2>/dev/null
	echo "$alarm" | while IFS= read -r a; do
		[ -n "$a" ] || continue
		case "$ALARM_PREV" in *"$a"*) ;; *) logger -t "batman-payload-$T" "host alarm: $a" ;; esac
	done
	ALARM_PREV=$alarm
	printf "{\"status\":\"%s\",\"tenant\":\"%s\",\"ts\":%s,\"detail\":\"see %s\"}\n" "$st" "$T" "$(date -u +%s)" "$VERIFY_LOG" > "$DRIFT_FILE" 2>/dev/null || true
	[ "$st" = DRIFT ] && logger -t "batman-payload-$T" "confinement DRIFT detected (see $VERIFY_LOG)"   # parsed by the harness
	sleep "$POLL"
done

# payload-guardian.sh — GENERIC procd runtime owner / guardian for a payload tenant (#156/#167).
#
# Sourced by a 4-line per-tenant init (/etc/init.d/batman-payload-<tenant>) that sets
# PAYLOAD_TENANT then `. /usr/lib/batman/payload-guardian.sh`. This is the app-agnostic successor
# to the bespoke deploy/ots/batman-ots.init: the same narrow #156 DoD (anti-bypass — on every boot
# the tenant's hardened stack is brought to its manifest config, so a hand-run `docker run` can't
# leave a non-hardened config in place; alarm-only reconcile, NO destructive re-assert), keyed on
# $PAYLOAD_TENANT and driven by the tenant's manifest via /usr/bin/payload-run.
#
# BOOT ORDERING (as batman-ots): dockerd is START=99 and "batman-payload-*" sorts before "dockerd",
# so this starts first AND dockerd cold-boot can exceed 2 min on a Pi4 (data-root on p6). The
# bring-up therefore runs UNDER procd with respawn — it waits for the docker socket (up to 90 s inside
# the instance, so a ready dockerd is picked up within 2 s instead of a 15 s respawn quantum), runs the
# arbiter, applies fw4 + `payload-run --converge`, then keepalive-watches the primary container; if
# anything is not ready it exits and procd respawns it until the stack is up. Idempotent.
#
# #274 (docs/design/274-payload-converge.md): converge = every container running, not restarting, and
# labelled with the CURRENT config fingerprint (`payload-run --cfg-hash`); otherwise `payload-run
# --converge` starts the unchanged stack in order (no rebuild on a normal boot) or rebuilds a changed one.
# Stop = graceful and tiered (/usr/lib/batman/payload-stop.sh; K08batman-prestop-payload + this K09),
# never rm, so the next boot is a start, not a rebuild.
#
# shellcheck shell=sh
# shellcheck disable=SC2016  # the '"$_T"' break-ins interpolate at DEFINITION time on purpose
#                            # (single-quoted procd command string) — same idiom as batman-ots.init.

APPS_DIR="${APPS_DIR:-/opt/batdata/apps}"
_T="${PAYLOAD_TENANT:?payload-guardian.sh: PAYLOAD_TENANT not set by the init stub}"
_DIR="$APPS_DIR/$_T"

start_service() {
	[ -d "$_DIR" ] || { echo "batman-payload[$_T]: $_DIR missing (payload not installed)"; return 1; }
	# a start ends any stop (#274: only start_service — and firstload's own S95 stop — clear the flag)
	rm -f "/tmp/batman-payload-$_T.stopping" "/tmp/batman-payload-$_T.stop0"
	procd_open_instance
	# The supervised command does the whole guarded bring-up, then blocks as a keepalive. It EXITS
	# (non-zero) if docker isn't ready or the primary container isn't up -> procd respawns it.
	# $_T / $_DIR are interpolated once here (single-quote break-in), mirroring batman-ots.init.
	procd_set_param command /bin/sh -c '
		T='"$_T"'
		DIR='"$_DIR"'
		MANIFEST=$(ls "$DIR"/*.manifest 2>/dev/null | head -1)
		NETALLOC=$(ls "$DIR"/*.net.alloc 2>/dev/null | head -1)
		DRIFT_FILE=/tmp/batman-payload-$T-drift.json
		VERIFY_LOG=/tmp/batman-payload-$T-verify.log
		RC_STATE=/tmp/batman-payload-$T-restarts.state
		INTERVAL=30
		i=0; until docker info >/dev/null 2>&1; do
			i=$((i + 1)); [ "$i" -gt 45 ] && { echo "batman-payload[$T]: waiting for dockerd"; exit 1; }
			sleep 2
		done
		[ -n "$MANIFEST" ] || { echo "batman-payload[$T]: no manifest in $DIR"; exit 1; }
		PRIMARY=$(awk "/^CONTAINER /{print \$2; exit}" "$MANIFEST")
		[ -n "$PRIMARY" ] || { echo "batman-payload[$T]: no CONTAINER in manifest"; exit 1; }
		NAMES=$(awk "/^CONTAINER /{print \$2}" "$MANIFEST")
		# arbiter: refuse to bring up a tenant that collides with an already-installed one.
		if [ -n "$NETALLOC" ] && command -v payload-arbiter >/dev/null 2>&1; then
			payload-arbiter "$NETALLOC" "'"$APPS_DIR"'" || { echo "batman-payload[$T]: arbiter REFUSED bring-up"; exit 1; }
		fi
		# #206: a fresh A/B slot has a pristine /etc/config/firewall with no dockert zone, so cross-container
		# east-west (postgres/rabbitmq) is silently dropped until the tenant fw4 rules are re-applied. Apply
		# them idempotently every start (needs dockerd iptables=0, baked in 99-batman-payload-docker).
		for f in "$DIR"/*.fw4.uci; do [ -f "$f" ] && sh "$f" >/dev/null 2>&1 || true; done
		# #206/#274: converge if ANY manifest container is not running, is restart-looping (#264 R2: a container
		# in restart backoff still reports State.Running=true), or was not created from the current config
		# (dockerd revives the OLD containers after an OTA). Missing label renders "" — an empty CFG never matches.
		CFG=$(payload-run --cfg-hash "$T" 2>/dev/null)
		_need=0; for c in $NAMES; do
			s=$(docker inspect -f "{{.State.Status}} {{.State.Restarting}} {{index .Config.Labels \"batman.cfg\"}}" "$c" 2>/dev/null)
			[ -n "$CFG" ] && [ "$s" = "running false $CFG" ] || _need=1; done
		if [ "$_need" = 1 ]; then
			echo "batman-payload[$T]: converging the stack (container down or config fingerprint changed)"
			# tells batman-autocommit the tenant is converging (bounded revert deferral)
			touch "/tmp/batman-payload-$T.converging"
			payload-run --converge "$T"; prc=$?
			rm -f "/tmp/batman-payload-$T.converging"
			# boot-to-ready evidence (daily-validation cleanstop-274 SLO): health gates passed by this uptime
			echo "batman-payload[$T]: converge done rc=$prc uptime=$(cut -d" " -f1 /proc/uptime)"
			[ "$prc" = 4 ] && { echo "batman-payload[$T]: tenant is being stopped — not converging"; exit 1; }
		fi
		# Reconcile loop — #156 Phase 1 = ALARM-ONLY (no destructive re-assert here; that is #97/#156
		# Phase 2). Each tick: optional in-place resource correction, then verify, publish a verdict.
		# T5 (#274): a dockerd restart (live-restore keeps the containers) must not end the guardian — wait
		# up to 120 s for the API; leave for respawn only when docker answers and PRIMARY is not running.
		: > "$RC_STATE"; down=0
		while :; do
			if ! docker info >/dev/null 2>&1; then
				down=$((down + 5)); [ "$down" -gt 120 ] && { echo "batman-payload[$T]: docker API down > 120 s — exiting for respawn"; exit 1; }
				sleep 5; continue
			fi
			down=0
			[ "$(docker inspect -f "{{.State.Running}}" "$PRIMARY" 2>/dev/null)" = true ] || break
			[ -x "$DIR/reconcile-resources.sh" ] && sh "$DIR/reconcile-resources.sh" >/tmp/batman-payload-$T-resources.log 2>&1 || true
			st=OK; : > "$VERIFY_LOG"   # truncate once per tick (entries below append)
			CFG=$(payload-run --cfg-hash "$T" 2>/dev/null)
			new=""
			for c in $NAMES; do
				s=$(docker inspect -f "{{.Id}} {{.RestartCount}} {{.State.Status}} {{.State.Restarting}} {{index .Config.Labels \"batman.cfg\"}}" "$c" 2>/dev/null)
				set -- $s
				# #206: liveness is part of the verdict
				[ "${3:-}" = running ] && [ "${4:-}" = false ] || { st=DRIFT; echo "container $c NOT running" >>"$VERIFY_LOG"; }
				# #274 D3(a): a crash loop that is "running" at every sample instant — RestartCount grew
				# since the previous tick for the same container ID (baseline: first tick / new ID)
				if [ -n "${1:-}" ]; then
					prev=$(awk -v c="$c" -v id="$1" "\$1==c && \$2==id {print \$3}" "$RC_STATE")
					[ -n "$prev" ] && [ "$2" -gt "$prev" ] 2>/dev/null && { st=DRIFT; echo "container $c restarted $(( $2 - prev ))x since the last check" >>"$VERIFY_LOG"; }
					new="$new$c $1 $2
"
				fi
				# #274 D3(b): config changed under a running stack (operator edit) — alarm only
				[ -n "$CFG" ] && [ -n "${5:-}" ] && [ "${5:-}" != "$CFG" ] && { st=DRIFT; echo "container $c config changed since start — restart the guardian to apply" >>"$VERIFY_LOG"; }
			done
			printf "%s" "$new" > "$RC_STATE"
			# only the tenant ROLLUP scripts (verify-profile-<tenant>.sh, with the dash) — NOT the
			# low-level helper verify-profile.sh (no dash; it needs an <app> arg and would false-alarm).
			for vp in "$DIR"/verify-profile-*.sh; do
				[ -x "$vp" ] || continue
				if "$vp" >>"$VERIFY_LOG" 2>&1; then :; else st=DRIFT; fi
			done
			printf "{\"status\":\"%s\",\"tenant\":\"%s\",\"ts\":%s,\"detail\":\"see %s\"}\n" "$st" "$T" "$(date -u +%s)" "$VERIFY_LOG" > "$DRIFT_FILE" 2>/dev/null || true
			[ "$st" = DRIFT ] && logger -t "batman-payload-$T" "confinement DRIFT detected (see $VERIFY_LOG)"
			sleep "$INTERVAL"
		done
		echo "batman-payload[$T]: primary $PRIMARY not running — exiting for respawn"; exit 1
	'
	procd_set_param respawn 30 15 0    # threshold 30s, respawn every 15s, unlimited retries
	procd_set_param stdout 1
	procd_set_param stderr 1
	procd_close_instance
}

stop_service() {
	# Graceful, tiered stop of the tenant; never rm, so the next start is a start, not a rebuild (#274).
	# At shutdown K08batman-prestop-payload has already stopped the client tiers; this (K09) stops the
	# stateful services and records the stop. An operator `stop` runs both halves here.
	[ -f /usr/lib/batman/payload-stop.sh ] || return 0
	# shellcheck source=/dev/null
	. /usr/lib/batman/payload-stop.sh
	pstop_final "$_T"
}

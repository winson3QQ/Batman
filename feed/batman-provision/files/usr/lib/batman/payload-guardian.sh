# payload-guardian.sh — GENERIC procd runtime owner / guardian for a payload tenant (#156/#167).
#
# Sourced by a 4-line per-tenant init (/etc/init.d/batman-payload-<tenant>) that sets
# PAYLOAD_TENANT then `. /usr/lib/batman/payload-guardian.sh`. This is the app-agnostic successor
# to the bespoke deploy/ots/batman-ots.init: the same narrow #156 DoD (anti-bypass — on every boot
# the tenant's hardened stack is re-brought-up, so a hand-run `docker run` can't leave a
# non-hardened config in place; alarm-only reconcile, NO destructive re-assert), but keyed on
# $PAYLOAD_TENANT and driven by the tenant's manifest via /usr/bin/payload-run.
#
# BOOT ORDERING (as batman-ots): dockerd is START=99 and "batman-payload-*" sorts before "dockerd",
# so this starts first AND dockerd cold-boot can exceed 2 min on a Pi4 (data-root on p6). The
# bring-up therefore runs UNDER procd with respawn — it waits for the docker socket, runs the
# arbiter, applies fw4 + payload-run, then keepalive-watches the primary container; if anything is
# not ready it exits and procd respawns it until the stack is up. Idempotent, so retries are safe.
#
# shellcheck shell=sh
# shellcheck disable=SC2016  # the '"$_T"' break-ins interpolate at DEFINITION time on purpose
#                            # (single-quoted procd command string) — same idiom as batman-ots.init.

APPS_DIR="${APPS_DIR:-/opt/batdata/apps}"
_T="${PAYLOAD_TENANT:?payload-guardian.sh: PAYLOAD_TENANT not set by the init stub}"
_DIR="$APPS_DIR/$_T"

start_service() {
	[ -d "$_DIR" ] || { echo "batman-payload[$_T]: $_DIR missing (payload not installed)"; return 1; }
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
		INTERVAL=30
		docker info >/dev/null 2>&1 || { echo "batman-payload[$T]: waiting for dockerd"; exit 1; }
		[ -n "$MANIFEST" ] || { echo "batman-payload[$T]: no manifest in $DIR"; exit 1; }
		PRIMARY=$(awk "/^CONTAINER /{print \$2; exit}" "$MANIFEST")
		[ -n "$PRIMARY" ] || { echo "batman-payload[$T]: no CONTAINER in manifest"; exit 1; }
		# arbiter: refuse to bring up a tenant that collides with an already-installed one.
		if [ -n "$NETALLOC" ] && command -v payload-arbiter >/dev/null 2>&1; then
			payload-arbiter "$NETALLOC" "'"$APPS_DIR"'" || { echo "batman-payload[$T]: arbiter REFUSED bring-up"; exit 1; }
		fi
		# #206: a fresh A/B slot has a pristine /etc/config/firewall with no dockert zone, so cross-container
		# east-west (postgres/rabbitmq) is silently dropped until the tenant fw4 rules are re-applied. Apply
		# them idempotently every start (needs dockerd iptables=0, baked in 99-batman-payload-docker).
		# Cost note: each *.fw4.uci does uci commit + fw4 reload (rebuilds the whole inet fw4 ruleset incl.
		# mesh zones). This runs once per guardian (procd) start; during a persistently-failing bring-up procd
		# respawns ~every 15s, so it reloads fw4 each cycle — acceptable (transient) but not free.
		for f in "$DIR"/*.fw4.uci; do [ -f "$f" ] && sh "$f" >/dev/null 2>&1 || true; done
		# #206: bring the stack up if ANY manifest container is not running, not just PRIMARY. PRIMARY is ots-db,
		# which the restart policy revives on its own after a reboot — a PRIMARY-only check would see it running
		# and never rebuild a dead opentakserver/parser (guardian blind-spot). payload-run applies fw4 + is idempotent.
		_need=0; for c in $(awk "/^CONTAINER /{print \$2}" "$MANIFEST"); do
			docker inspect -f "{{.State.Running}}" "$c" 2>/dev/null | grep -q true || _need=1; done
		[ "$_need" = 1 ] && payload-run "$T"
		# Reconcile loop — #156 Phase 1 = ALARM-ONLY (no destructive re-assert here; that is #97/#156
		# Phase 2). Each tick: optional in-place resource correction, then verify, publish a verdict.
		while docker inspect -f "{{.State.Running}}" "$PRIMARY" >/dev/null 2>&1; do
			[ -x "$DIR/reconcile-resources.sh" ] && sh "$DIR/reconcile-resources.sh" >/tmp/batman-payload-$T-resources.log 2>&1 || true
			st=OK; : > "$VERIFY_LOG"   # truncate once per tick (entries below append)
			# #206: liveness is part of the verdict — a manifest container being down (e.g. opentakserver
			# crash-looping while PRIMARY ots-db stays up) must surface as DRIFT, not a silent OK.
			for c in $(awk "/^CONTAINER /{print \$2}" "$MANIFEST"); do
				docker inspect -f "{{.State.Running}}" "$c" 2>/dev/null | grep -q true || { st=DRIFT; echo "container $c NOT running" >>"$VERIFY_LOG"; }
			done
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
	# Tear down the tenant's containers (names read from its manifest, reverse lifecycle order).
	_M="$_DIR/$_T.manifest"
	[ -f "$_M" ] || return 0
	# collect names, then rm -f in reverse
	_names=$(awk '/^CONTAINER /{print $2}' "$_M")
	_rev=""
	for _n in $_names; do _rev="$_n $_rev"; done
	for _n in $_rev; do docker rm -f "$_n" >/dev/null 2>&1 || true; done
}

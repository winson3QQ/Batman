#!/bin/sh
# verify-profile.sh <app> [env-file] — generic confinement drift-check (#98/#153 §5; #156 detection).
#
# App-agnostic: asserts `docker inspect <app>` reflects the committed <app>.hardening.env that was
# actually applied. Runs on the busybox node. NO YAML — consumes the generated env only.
#
# Exit codes (the #156 reconciler branches on these):
#   0 = OK       running AND conformant to the profile
#   1 = DRIFT    running but does NOT match the profile  -> caller may ALARM
#   2 = usage    bad args / missing env file
#   3 = UNKNOWN  cannot judge (inspect failed / not running / too fresh) -> caller SKIPS, must NOT alarm
#
# Axis coverage:
#   - value-checked only when the flag is present in $HARDEN_FLAGS (an intentionally-deferred axis
#     emits no flag and is not asserted — its status lives in the profile's assessment block);
#   - BASELINE axes (privileged / cap-add / seccomp / docker-socket / network) are asserted ALWAYS,
#     because a bypass launch (`docker run` without $HARDEN_FLAGS) drops the flags yet must still be
#     caught — those are the anti-bypass invariants (#156).
#
# #156 detection contract (F5): a read we cannot perform must return UNKNOWN(3), NEVER DRIFT — so an
# SD/p6 I/O stall or a container removed mid-check can't fire a false alarm. This is enforced by taking
# ONE authoritative `docker inspect` blob up front (single point of failure -> exit 3) and reading EVERY
# field from that captured blob — no per-axis re-inspect that could read empty and be misjudged.
set -e
app="$1"; [ -n "$app" ] || { echo "usage: verify-profile.sh <app> [env-file]"; exit 2; }
env_file="${2:-/opt/batdata/apps/$app/$app.hardening.env}"
[ -f "$env_file" ] || env_file="$(cd "$(dirname "$0")/../deploy/$app" 2>/dev/null && pwd)/$app.hardening.env"
[ -f "$env_file" ] || { echo "no env file for $app ($env_file)"; exit 2; }
# shellcheck disable=SC1090
. "$env_file"
MIN_UPTIME="${MIN_UPTIME:-15}"
FL=" $HARDEN_FLAGS "
fail=0
pass() { echo "PASS  $1"; }
bad()  { echo "FAIL  $1"; fail=1; }
has()  { case "$FL" in *" $1 "*) return 0;; *" $1="*) return 0;; esac; return 1; }

# convert a docker size (512m / 256mb / 1g / 1024k / 5368709120) to bytes; empty on parse failure.
to_bytes() {
	v="$1"; [ -n "$v" ] || return 0
	n=$(printf '%s' "$v" | sed -n 's/^\([0-9][0-9]*\).*/\1/p'); [ -n "$n" ] || return 0
	u=$(printf '%s' "$v" | sed -n 's/^[0-9][0-9]*\(.*\)/\1/p')
	case "$u" in
		b|"")       echo "$n";;
		k|kb|K|KB)  echo $(( n * 1024 ));;
		m|mb|M|MB)  echo $(( n * 1024 * 1024 ));;
		g|gb|G|GB)  echo $(( n * 1024 * 1024 * 1024 ));;
		*)          return 0;;
	esac
}

# seconds since the container (re)started. StartedAt and `now` share the SAME node clock, so the DELTA
# is valid even though the absolute clock may be wrong (no RTC, #174). Empty if unparseable -> caller
# then skips the freshness gate (fail-safe: a judged mid-restart is at worst a false alarm, not a miss).
uptime_secs() {
	s=${1%.*}; s=${s%Z}                       # strip fractional seconds + trailing Z -> 2026-09-18T13:22:04
	[ -n "$s" ] || return 0
	st=$(date -u -D '%Y-%m-%dT%H:%M:%S' -d "$s" +%s 2>/dev/null) || st=""
	[ -n "$st" ] || st=$(date -u -d "$s" +%s 2>/dev/null) || st=""   # fallback: some busybox parse ISO directly
	[ -n "$st" ] || return 0
	now=$(date -u +%s)
	echo $(( now - st ))
}

# --- inspect strategy (F1/F5): per-field, SIMPLE templates. A simple `docker inspect -f` uses docker's
# TYPED decode, which returns the zero value for an omitempty-nil field (e.g. a container without tmpfs
# gives `map[]`, not an error). A single big MULTILINE template instead map-decodes with missingkey=error
# and aborts (rc=1) on a nil map like Tmpfs — which would misread a fully UNhardened bypass as UNKNOWN
# instead of DRIFT (verified on the node). So we read field-by-field, and bracket the reads with an
# existence PREflight and POSTflight: a container that is absent, not-running, too-fresh, OR vanishes
# mid-check yields UNKNOWN(3), never a false DRIFT. (Command substitution can't exit the parent, so the
# postflight re-check is how we get the "inspect failed mid-check -> skip" guarantee.)
ins() { docker inspect "$app" -f "$1" 2>/dev/null; }

# (a) preflight existence + liveness + freshness
running=$(docker inspect "$app" -f '{{.State.Running}}' 2>/dev/null) || {
	echo "UNKNOWN  $app: docker inspect failed (absent or daemon unreachable) -> skip"; exit 3; }
[ "$running" = "true" ] || {
	echo "UNKNOWN  $app: not running (State.Running='$running') -> liveness is the bring-up path, not a hardening verdict"; exit 3; }
started=$(ins '{{.State.StartedAt}}')
age=$(uptime_secs "$started")
if [ -n "$age" ] && [ "$age" -lt "$MIN_UPTIME" ]; then
	echo "UNKNOWN  $app: uptime ${age}s < MIN_UPTIME ${MIN_UPTIME}s (mid-restart, too fresh to judge) -> skip"; exit 3
fi

# (b) read every axis (each a simple template -> typed decode, safe on nil fields)
ro=$(ins '{{.HostConfig.ReadonlyRootfs}}'); capdrop=$(ins '{{.HostConfig.CapDrop}}'); capadd=$(ins '{{.HostConfig.CapAdd}}')
secopt=$(ins '{{.HostConfig.SecurityOpt}}'); cuser=$(ins '{{.Config.User}}'); tmpfs=$(ins '{{.HostConfig.Tmpfs}}')
nanocpus=$(ins '{{.HostConfig.NanoCpus}}'); pids=$(ins '{{.HostConfig.PidsLimit}}'); mem=$(ins '{{.HostConfig.Memory}}')
priv=$(ins '{{.HostConfig.Privileged}}'); mounts=$(ins '{{range .Mounts}}{{.Source}} {{end}}')
nets=$(ins '{{range $k, $v := .NetworkSettings.Networks}}{{$k}} {{end}}')

# (c) postflight: if the container vanished during (b), discard the (possibly partial) reads as UNKNOWN
[ "$(docker inspect "$app" -f '{{.State.Running}}' 2>/dev/null)" = "true" ] || {
	echo "UNKNOWN  $app: container vanished mid-check -> skip"; exit 3; }
echo "  StartedAt=$started  age=${age:-unknown}s (>= ${MIN_UPTIME}s or unparseable)"
pass "State.Running=true"

# ---------- per-axis (value-checked only where the flag was applied) ----------
has --read-only && { [ "$ro" = "true" ] && pass "read-only" || bad "read-only not set [$ro]"; }
if has --cap-drop; then printf '%s' "$capdrop" | grep -qi 'ALL' && pass "cap-drop=ALL" || bad "cap-drop!=ALL [$capdrop]"; fi
if has --security-opt; then
	# F2: a bare substring match passes `no-new-privileges=false`; reject the disabled form explicitly.
	case "$secopt" in
		*no-new-privileges=false*|*no-new-privileges:false*) bad "no-new-privileges DISABLED [$secopt]";;
		*no-new-privileges*)                                 pass "no-new-privileges";;
		*)                                                   bad "no-new-privileges missing [$secopt]";;
	esac
fi
if has --user; then
	want=$(printf '%s' "$HARDEN_FLAGS" | sed -n 's/.*--user \([^ ]*\).*/\1/p')
	[ "$cuser" = "$want" ] && pass "user=$cuser" || bad "user got[$cuser] want[$want]"
fi
# tmpfs field (typed decode) = `map[/tmp:rw,...]` or `map[]`; match the exact /tmp mount key, not /tmpfoo
has --tmpfs && { case "$tmpfs" in *'/tmp:'*) pass "tmpfs /tmp present";; *) bad "tmpfs /tmp missing [$tmpfs]";; esac; }
if has --cpus; then
	wc=$(printf '%s' "$HARDEN_FLAGS" | sed -n 's/.*--cpus \([^ ]*\).*/\1/p')
	wn=$(awk -v c="$wc" 'BEGIN{printf "%.0f", c*1000000000}')   # %.0f, not %d: %d overflows 32-bit at cpus>=3
	[ "$nanocpus" = "$wn" ] && pass "cpus=$wc" || bad "NanoCpus got[$nanocpus] want[$wn]"
fi
if has --pids-limit; then
	wp=$(printf '%s' "$HARDEN_FLAGS" | sed -n 's/.*--pids-limit \([^ ]*\).*/\1/p')
	[ "$pids" = "$wp" ] && pass "pids-limit=$wp" || bad "PidsLimit got[$pids] want[$wp]"
fi
# memory: VALUE compare, not presence (finding 3). memcg must be on (docker-in-image #159).
if has --memory; then
	wmraw=$(printf '%s' "$HARDEN_FLAGS" | sed -n 's/.*--memory \([^ ]*\).*/\1/p')
	wm=$(to_bytes "$wmraw")
	if [ -z "$wm" ]; then bad "memory: cannot parse profile value [$wmraw]"
	elif [ "$mem" = "$wm" ]; then pass "memory=$wmraw ($mem)"
	else bad "memory got[$mem] want[$wmraw=$wm]"; fi
fi

# ---------- baseline invariants: asserted ALWAYS (a bypass drops flags but these must still hold) ----------
[ "$priv" = "false" ] && pass "not privileged" || bad "privileged! [$priv]"
# cap-ADD must be empty — `--cap-drop=ALL --cap-add=SYS_ADMIN` otherwise passes the cap-drop check
if [ -z "$capadd" ] || [ "$capadd" = "[]" ] || [ "$capadd" = "<no value>" ]; then pass "no cap-add"
else bad "cap-add present! [$capadd]"; fi
# seccomp: profile is 'default' -> SecurityOpt must carry NO seccomp= entry; any override (unconfined
# OR a permissive custom profile) is drift
case "$secopt" in *seccomp=*) bad "seccomp overridden! [$secopt] (profile expects default)";; *) pass "seccomp=default (not overridden)";; esac
# docker socket never mounted
printf '%s' "$mounts" | grep -q 'docker.sock' && bad "docker socket mounted! [$mounts]" || pass "socket not mounted"
# network attachment: must be EXACTLY ots-net (F3: host+ots-net together is still a bypass)
nets_trim=$(printf '%s' "$nets" | tr -s ' \t' '  ' | sed 's/^ *//; s/ *$//')
[ "$nets_trim" = "ots-net" ] && pass "network=ots-net (only)" || bad "network not exactly ots-net! [$nets_trim]"

echo "----"; [ "$fail" = 0 ] && echo "verify-profile $app: OK" || echo "verify-profile $app: DRIFT"
exit $fail

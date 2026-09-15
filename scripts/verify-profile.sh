#!/bin/sh
# verify-profile.sh <app> [env-file] — generic drift-check (#98/#153 §5).
# App-agnostic: asserts `docker inspect <app>` reflects the committed <app>.hardening.env that was
# actually applied, AND the container is Running with uptime > MIN_UPTIME (a crash-looping container
# still reports its requested config in inspect, so State is checked too). Runs on the busybox node.
# No YAML here — it consumes the generated env only. Only axes present in $HARDEN_FLAGS are checked
# (values==applied); an axis intentionally deferred (e.g. fts-ui --read-only, --memory) emits no flag
# and is not asserted — its `planned/blocked/deferred` status lives in the profile's assessment block.
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
ins() { docker inspect "$app" -f "$1" 2>/dev/null; }
pass() { echo "PASS  $1"; }
bad()  { echo "FAIL  $1"; fail=1; }
has()  { case "$FL" in *" $1 "*) return 0;; *" $1="*) return 0;; esac; return 1; }

# liveness — inspect alone is not enough (B2)
[ "$(ins '{{.State.Running}}')" = "true" ] && pass "State.Running=true" || bad "container not Running"
started=$(ins '{{.State.StartedAt}}'); echo "  StartedAt=$started (want stable > ${MIN_UPTIME}s; re-run to confirm not crash-looping)"

# per-axis, only when the flag was actually applied
has --read-only && { [ "$(ins '{{.HostConfig.ReadonlyRootfs}}')" = "true" ] && pass "read-only" || bad "read-only not set"; }
if has --cap-drop; then ins '{{.HostConfig.CapDrop}}' | grep -qi 'ALL' && pass "cap-drop=ALL" || bad "cap-drop!=ALL"; fi
has --security-opt && { ins '{{.HostConfig.SecurityOpt}}' | grep -q 'no-new-privileges' && pass "no-new-privileges" || bad "no-new-privileges missing"; }
# seccomp must never be unconfined
ins '{{.HostConfig.SecurityOpt}}' | grep -q 'seccomp=unconfined' && bad "seccomp unconfined!" || pass "seccomp not unconfined"
# never privileged / no socket (always asserted — baseline)
[ "$(ins '{{.HostConfig.Privileged}}')" = "false" ] && pass "not privileged" || bad "privileged!"
ins '{{range .Mounts}}{{.Source}}{{"\n"}}{{end}}' | grep -q '/docker.sock' && bad "docker socket mounted!" || pass "socket not mounted"
# user
if has --user; then
  want=$(printf '%s' "$HARDEN_FLAGS" | sed -n 's/.*--user \([^ ]*\).*/\1/p')
  got=$(ins '{{.Config.User}}'); [ "$got" = "$want" ] && pass "user=$got" || bad "user got[$got] want[$want]"
fi
# cpus  (--cpus X -> NanoCpus = X*1e9)
if has --cpus; then
  wc=$(printf '%s' "$HARDEN_FLAGS" | sed -n 's/.*--cpus \([^ ]*\).*/\1/p')
  wn=$(awk -v c="$wc" 'BEGIN{printf "%d", c*1000000000}')
  gn=$(ins '{{.HostConfig.NanoCpus}}'); [ "$gn" = "$wn" ] && pass "cpus=$wc" || bad "NanoCpus got[$gn] want[$wn]"
fi
# pids
if has --pids-limit; then
  wp=$(printf '%s' "$HARDEN_FLAGS" | sed -n 's/.*--pids-limit \([^ ]*\).*/\1/p')
  gp=$(ins '{{.HostConfig.PidsLimit}}'); [ "$gp" = "$wp" ] && pass "pids-limit=$wp" || bad "PidsLimit got[$gp] want[$wp]"
fi
# memory (only if applied; deferred by default)
if has --memory; then
  gm=$(ins '{{.HostConfig.Memory}}'); [ "$gm" != "0" ] && pass "memory set ($gm)" || bad "memory not enforced (memcg off?)"
fi
echo "----"; [ "$fail" = 0 ] && echo "verify-profile $app: OK" || echo "verify-profile $app: DRIFT"
exit $fail

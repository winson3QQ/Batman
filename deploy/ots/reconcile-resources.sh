#!/bin/sh
# reconcile-resources.sh — #156 Way-2, pillar 2: in-place resource-axis correction.
#
# The ONLY correction #156 v1.1 performs. Resource axes (--cpus/--memory/--pids-limit) are the sole
# confinement axes docker can mutate on a RUNNING container (`docker update`, verified live on cgroup v2:
# StartedAt unchanged, no restart). Security axes are create-time-fixed and cannot be loosened live, so
# there is nothing to correct there — prevention (admission, #97) owns those. This is deliberately
# non-destructive: it NEVER rm/recreates a container (that path was rejected — 156-phase2-correction.md).
#
# Honest scope (156-field-worthy.md §5): T4 (a live `docker update`) has no field trigger on an
# unattended node, so this is a cheap belt-and-suspenders (and the in-place fix for a bad profile that
# shipped a wrong resource value), not threat-reduction. It runs each reconcile tick; a no-op when matched.
#
# Maintenance pause (review finding): touch /tmp/batman-ots-pause to suspend correction while tuning
# resources live; auto-expires after PAUSE_TTL_MIN so a forgotten pause can't disable it forever.
set -e
HERE=$(cd "$(dirname "$0")" && pwd)
PAUSE=/tmp/batman-ots-pause
PAUSE_TTL_MIN="${PAUSE_TTL_MIN:-60}"

# container -> hardening.env (same pairing as verify-profile-ots.sh)
set -- \
  "opentakserver:ots" "ots_cot_parser:ots" "ots_eud_handler:ots" "ots_eud_handler_ssl:ots" \
  "ots-db:ots-db" "rabbitmq:rabbitmq"

# maintenance pause (auto-expiring): a fresh pause file suspends correction
if [ -f "$PAUSE" ] && find "$PAUSE" -mmin "-$PAUSE_TTL_MIN" 2>/dev/null | grep -q .; then
	echo "reconcile-resources: paused ($PAUSE fresh < ${PAUSE_TTL_MIN}min) — no correction"; exit 0
fi

to_bytes() {   # 512m -> 536870912 ; empty on parse fail
	v="$1"; [ -n "$v" ] || return 0
	n=$(printf '%s' "$v" | sed -n 's/^\([0-9][0-9]*\).*/\1/p'); [ -n "$n" ] || return 0
	u=$(printf '%s' "$v" | sed -n 's/^[0-9][0-9]*\(.*\)/\1/p')
	case "$u" in
		b|"") echo "$n";; k|kb|K|KB) echo $(( n*1024 ));;
		m|mb|M|MB) echo $(( n*1024*1024 ));; g|gb|G|GB) echo $(( n*1024*1024*1024 ));; *) return 0;;
	esac
}
val() { printf '%s' "$1" | sed -n "s/.*$2 \\([^ ]*\\).*/\\1/p"; }   # extract "$2 <value>" from flags

corrected=0
for pair in "$@"; do
	cname=${pair%:*}; env=${pair#*:}; envf="$HERE/$env.hardening.env"
	[ -f "$envf" ] || { echo "reconcile-resources: $cname: no $envf — skip"; continue; }
	# container must be running to update; a not-running one is bring-up's job, not ours
	[ "$(docker inspect -f '{{.State.Running}}' "$cname" 2>/dev/null)" = "true" ] || { echo "reconcile-resources: $cname: not running — skip"; continue; }
	# shellcheck disable=SC1090
	HARDEN_FLAGS=""; . "$envf"; FL="$HARDEN_FLAGS"
	wc=$(val "$FL" --cpus); wm=$(val "$FL" --memory); wp=$(val "$FL" --pids-limit)
	wnc=$(awk -v c="$wc" 'BEGIN{if(c=="")exit; printf "%.0f", c*1000000000}')
	wmb=$(to_bytes "$wm")
	upd=""
	[ -n "$wnc" ] && [ "$(docker inspect -f '{{.HostConfig.NanoCpus}}' "$cname" 2>/dev/null)" != "$wnc" ] && upd="$upd --cpus $wc"
	[ -n "$wmb" ] && [ "$(docker inspect -f '{{.HostConfig.Memory}}' "$cname" 2>/dev/null)" != "$wmb" ] && upd="$upd --memory $wm"
	[ -n "$wp" ]  && [ "$(docker inspect -f '{{.HostConfig.PidsLimit}}' "$cname" 2>/dev/null)" != "$wp" ]  && upd="$upd --pids-limit $wp"
	if [ -n "$upd" ]; then
		# shellcheck disable=SC2086
		if docker update $upd "$cname" >/dev/null 2>&1; then
			echo "reconcile-resources: CORRECTED $cname ->$upd (in place, no restart)"
			logger -t batman-ots "resource drift corrected: $cname$upd" 2>/dev/null || true
			corrected=$((corrected+1))
		else
			echo "reconcile-resources: FAILED to update $cname ($upd)"
		fi
	fi
done
echo "reconcile-resources: done (corrected=$corrected)"
exit 0

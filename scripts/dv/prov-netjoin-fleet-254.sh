#!/bin/bash
# scripts/dv/prov-netjoin-fleet-254.sh — #254 tier-B unit prov-netjoin-fleet-254 (docs/design/254-h23-harness.md §6.2,
# §7.2): both fleet nodes provisioned onto the network they already run, without dropping the mesh.
#   04 snap (pr_begin) -> 02 snap (its own lease, run id <run>p) -> both claimed by this run's owner key (pk_proof first,
#   F38) -> 04 net-apply --first with the fleet's own values (mesh id / channel / key read from uci ON the node, fd 3;
#   the key never leaves the node) -> member, 02 still a neighbour -> 02 the same -> member, 04 a neighbour of 02 ->
#   both LOCKED, both members of the same net (same mesh id hash, wireless unchanged) -> restore 02 FIRST (p5 + overlay,
#   reboot; reached through 04, 02 has no ethernet) -> 02 back legacy, a neighbour -> 04 restored (pr_end).
#   A failed restore of 02 leaves it LOCKED with the run's owner key: the keys are kept and the run stops NEEDS-PERSON.
# Type: — / A / F on 04, F on 02. Side effects: both claimed for ~20 min, 2 reboots each, 02 out of reach while 04
# reboots.
set -u
PR_UNIT=prov-netjoin-fleet-254
# shellcheck source=scripts/dv/prov-254.sh
. "$(dirname "$0")/prov-254.sh"
RUN04=$RUN; RUN02=${RUN}p; NODE04=$NODE; MAC04=$MAC; MAC02=""; SNAP02=0
WSUM='printf "%s|%s|%s" "$(uci -q get wireless.default_radio1.mesh_id)" "$(uci -q get wireless.radio1.channel)" "$(uci -q get wireless.default_radio1.key | sha256sum | cut -c1-16)"'
# the fleet's own values, read on the node (fd 3 of provclient): nothing secret crosses to the host
FLEET_FD3="umask 077; printf 'mesh_id=%s\nchannel=%s\nbw=2\nsae=%s\n' \"\$(uci -q get wireless.default_radio1.mesh_id)\" \"\$(uci -q get wireless.radio1.channel)\" \"\$(uci -q get wireless.default_radio1.key)\""
# as02 <cmd...>: run a library step against 02 (NODE / MAC / RUN switched, switched back after)
as02(){ local rc; NODE=$PEER; MAC=$MAC02; RUN=$RUN02; PRD=/tmp/run/batman-dv/bt/$RUN; "$@"; rc=$?; NODE=$NODE04; MAC=$MAC04; RUN=$RUN04; PRD=/tmp/run/batman-dv/bt/$RUN; return $rc; }
nbsnap(){ local o; o=$(nb snap "$RUN"); say "$(echo "$o" | tail -1)"; grep -q "^SNAP $RUN" <<< "$o"; }
join(){	# on the current NODE: net-apply --first with the fleet values -> member
	local r i
	r=$(pr_pc owner.pem FD3="$FLEET_FD3" -- net-apply --first "$OWNER"); echo "$r" | grep -v '^NETCFG' | sed 's/^/    /'
	grep -q "RESULT net.apply code=0 " <<< "$r" || { no "$NODE: net-apply --first: $(grep RESULT <<< "$r")"; return 1; }
	i=$(pr_info); case " $i " in *" state=member "*) ok "$NODE: member of the fleet net ($i)" ;; *) no "$NODE: after the join: $i"; return 1 ;; esac
}
neigh(){ local t=0; while [ $t -lt 18 ]; do qr 'batctl n 2>/dev/null | tail -n +3 | grep -q .' && return 0; sleep 10; t=$((t + 1)); done; return 1; }
fleet(){
	local w4 w2 o
	MAC02=$(qp 'cat /sys/class/net/eth0/address'); [ -n "$MAC02" ] || { no "02 unreachable"; return 1; }
	w4=$(qr "$WSUM"); w2=$(qp "$WSUM"); say "wireless before: 04 [${w4%|*}|…] 02 [${w2%|*}|…]"
	[ "$w4" = "$w2" ] || { no "02 and 04 are not on the same net ($w4 / $w2)"; return 1; }
	o=$(as02 pr_acquire "$(( PR_DEADLINE - $(mono) ))") || { echo "$o"; no "02 lease"; return 1; }; echo "$o"
	as02 nbsnap || { no "02 snapshot"; return 1; }
	SNAP02=1
	pr_keys && pr_pc_place && pr_claim || return 1
	as02 pr_pc_place && as02 pr_claim || return 1
	join || return 1
	neigh && ok "04: 02 still a neighbour after 04's join" || { no "04 lost 02 after its join"; return 1; }
	as02 join || return 1
	as02 neigh && ok "02: 04 a neighbour after 02's join" || { no "02 lost 04 after its join"; return 1; }
	[ "$(qr 'cat /opt/batdata/state/lock-status')" = LOCKED ] && [ "$(qp 'cat /opt/batdata/state/lock-status')" = LOCKED ] && ok "both LOCKED" || no "lock-status 04 [$(qr 'cat /opt/batdata/state/lock-status')] 02 [$(qp 'cat /opt/batdata/state/lock-status')]"
	[ "$(qr "$WSUM")" = "$w4" ] && [ "$(qp "$WSUM")" = "$w2" ] && ok "wireless unchanged on both (mesh id, channel, key hash)" || no "wireless changed by the join"
}
restore02(){
	local o
	as02 pr_restore || { pr_needs_person "02 restore failed — 02 is LOCKED with this run's owner key; keys kept in $WSLK"; return 1; }
	o=$(as02 nb finish "$RUN02"); say "02: $(echo "$o" | tail -1)"
	o=$(as02 pl release); say "02 lease: $o"
	SNAP02=0
	PR_PEER_BOOT=$(qp 'cut -c1-8 /proc/sys/kernel/random/boot_id')   # 02 rebooted on purpose; from here it must not
	[ "$(qp 'cat /opt/batdata/state/lock-status')" = UNPROVISIONED ] && ok "02 back legacy (UNPROVISIONED)" || no "02 lock-status after its restore: $(qp 'cat /opt/batdata/state/lock-status')"
}
pr_begin 3600 || { pr_result; exit 1; }
if ! fleet; then
	[ "$SNAP02" = 1 ] && { restore02 || { pr_result; exit 1; }; }
	pr_abort "fleet join"; pr_result; exit 1
fi
restore02 || { pr_result; exit 1; }
pr_end
pr_result

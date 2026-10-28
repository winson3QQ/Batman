#!/bin/bash
# scripts/dv/prov-netjoin-fleet-254.sh — #254 tier-B unit prov-netjoin-fleet-254 (docs/design/254-h23-harness.md §6.2,
# §7.2): both fleet nodes provisioned onto the network they already run, as ONE provisioning network, without dropping
# the mesh.
#   04 snap (pr_begin) -> 02 snap (its own lease, run id <run>p) -> both claimed by this run's owner key (pk_proof first,
#   F38) -> 04 net-apply --first with the fleet's own values (mesh id / channel / key read from uci ON the node, fd 3; the
#   key never leaves the node) -> member, 02 still a neighbour -> 02 net-apply --join with 04's signed net_config
#   (review A-M2: run 1 made two networks, net_id 1f74e670… vs 5593017…) -> member of the SAME net_id, 04 a neighbour
#   of 02 -> both LOCKED, wireless unchanged -> restore 02 FIRST (p5 + overlay, reboot; reached through 04, 02 has no
#   ethernet) -> 02 back legacy, a neighbour -> 04 restored (pr_end).
#   The net_secrets' root secret is random per node (provclient); P1 checks nothing about it.
# Failure / death (review A-M3, B-M5): if 02 cannot be reached, 04 is restored first (ethernet) and 02 retried for 600 s;
# any exit with 02 still claimed (SNAP02=1) or inside an `as02` step switches back to 04, lets 04 restore, then writes a
# NEEDS-PERSON naming 02's run id; the owner keys stay in $WSLK.
# Type: — / A / F on 04, F on 02. Side effects: both claimed for ~20 min, 2 reboots each, 02 out of reach while 04
# reboots.
set -u
PR_UNIT=prov-netjoin-fleet-254
# shellcheck source=scripts/dv/prov-254.sh
. "$(dirname "$0")/prov-254.sh"
RUN04=$RUN; RUN02=${RUN}p; NODE04=$NODE; MAC04=$MAC; MAC02=""; SNAP02=0; IN02=0; NETCFG04=""; NETID04=""
WSUM='printf "%s|%s|%s" "$(uci -q get wireless.default_radio1.mesh_id)" "$(uci -q get wireless.radio1.channel)" "$(uci -q get wireless.default_radio1.key | sha256sum | cut -c1-16)"'
# the fleet's own values, read on the node (fd 3 of provclient): nothing secret crosses to the host
FLEET_FD3="umask 077; printf 'mesh_id=%s\nchannel=%s\nbw=2\nsae=%s\n' \"\$(uci -q get wireless.default_radio1.mesh_id)\" \"\$(uci -q get wireless.radio1.channel)\" \"\$(uci -q get wireless.default_radio1.key)\""
back04(){ NODE=$NODE04; MAC=$MAC04; RUN=$RUN04; PRD=/tmp/run/batman-dv/bt/$RUN; }
# as02 <cmd...>: run a library step against 02. Switches NODE / MAC / RUN / PRD and keeps 04's PR_DEADLINE / PR_RESTORING
# / PR_SNAPPED aside (review A-m4); IN02 tells the exit trap to switch back before it acts (review B-M5)
G_DL=0; G_RS=0; G_SN=0
as02(){
	local rc
	G_DL=$PR_DEADLINE; G_RS=$PR_RESTORING; G_SN=$PR_SNAPPED; IN02=1
	NODE=$PEER; MAC=$MAC02; RUN=$RUN02; PRD=/tmp/run/batman-dv/bt/$RUN; PR_RESTORING=0; PR_SNAPPED=$SNAP02
	"$@"; rc=$?
	back04; PR_DEADLINE=$G_DL; PR_RESTORING=$G_RS; PR_SNAPPED=$G_SN; IN02=0
	return $rc
}
nbsnap(){ local o; o=$(nb snap "$RUN"); say "$(echo "$o" | tail -1)"; grep -q "^SNAP $RUN" <<< "$o"; }
member_ok(){ local i; i=$(pr_info); case " $i " in *" state=member "*) ok "$NODE: member ($i)" ;; *) no "$NODE: after the join: $i"; return 1 ;; esac; }
join04(){	# 04: a new network from the fleet values -> NETCFG04 / NETID04
	local r
	r=$(pr_pc owner.pem FD3="$FLEET_FD3" -- net-apply --first "$OWNER"); echo "$r" | grep -v '^NETCFG' | sed 's/^/    /'
	grep -q "RESULT net.apply code=0 " <<< "$r" || { no "04: net-apply --first: $(grep RESULT <<< "$r")"; return 1; }
	NETCFG04=$(sed -n 's/^NETCFG //p' <<< "$r"); NETID04=$(sed -n 's/.* net_id=\([0-9a-f]*\) .*/\1/p' <<< "$r")
	[ -n "$NETCFG04" ] && [ -n "$NETID04" ] || { no "04: no net_config / net_id in the reply"; return 1; }
	member_ok
}
join02(){	# 02 (inside as02): JOIN 04's network — its signed net_config, 02's own secrets
	local r id
	r=$(pr_pc owner.pem FD3="$FLEET_FD3" -- net-apply --join "$OWNER" "$NETCFG04"); echo "$r" | sed 's/^/    /'
	grep -q "RESULT net.apply(join) code=0 " <<< "$r" || { no "02: net-apply --join: $(grep RESULT <<< "$r")"; return 1; }
	id=$(sed -n 's/.* net_id=\([0-9a-f]*\) .*/\1/p' <<< "$r")
	if [ "$id" = "$NETID04" ]; then ok "02 joined 04's network (net_id $id)"; else no "02's net_id [$id] != 04's [$NETID04]"; return 1; fi
	member_ok
}
neigh(){ local t=0; while [ $t -lt 18 ]; do nb02 && return 0; sleep 10; t=$((t + 1)); done; return 1; }
fleet(){
	local w4 w2 o
	MAC02=$(qp 'cat /sys/class/net/eth0/address'); [ -n "$MAC02" ] || { no "02 unreachable"; return 1; }
	w4=$(qr "$WSUM"); w2=$(qp "$WSUM"); say "wireless before: 04 [${w4%|*}|…] 02 [${w2%|*}|…]"
	[ "$w4" = "$w2" ] || { no "02 and 04 are not on the same mesh ($w4 / $w2)"; return 1; }
	o=$(as02 pr_acquire "$(( PR_DEADLINE - $(mono) ))") || { echo "$o"; no "02 lease"; return 1; }; echo "$o"
	as02 nbsnap || { no "02 snapshot"; return 1; }
	SNAP02=1
	pr_keys && pr_pc_place && pr_claim || return 1
	as02 pr_pc_place && as02 pr_claim || return 1
	join04 || return 1
	neigh && ok "04: 02 still a neighbour after 04's join" || { no "04 lost 02 after its join"; return 1; }
	as02 join02 || return 1
	as02 neigh && ok "02: 04 a neighbour after 02's join" || { no "02 lost 04 after its join"; return 1; }
	[ "$(qr 'cat /opt/batdata/state/lock-status')" = LOCKED ] && [ "$(qp 'cat /opt/batdata/state/lock-status')" = LOCKED ] && ok "both LOCKED" || no "lock-status 04 [$(qr 'cat /opt/batdata/state/lock-status')] 02 [$(qp 'cat /opt/batdata/state/lock-status')]"
	[ "$(qr "$WSUM")" = "$w4" ] && [ "$(qp "$WSUM")" = "$w2" ] && ok "wireless unchanged on both (mesh id, channel, key hash)" || no "wireless changed by the join"
}
restore02(){
	local o
	as02 pr_restore || { pr_needs_person "02 restore failed (run $RUN02) — 02 is LOCKED + member with this run's owner key; keys kept in $WSLK"; return 1; }
	o=$(as02 nb finish "$RUN02"); say "02: $(echo "$o" | tail -1)"
	o=$(as02 pl release); say "02 lease: $o"
	SNAP02=0
	PR_PEER_BOOT=$(qp 'cut -c1-8 /proc/sys/kernel/random/boot_id')   # 02 rebooted on purpose; from here it must not
	[ "$(qp 'cat /opt/batdata/state/lock-status')" = UNPROVISIONED ] && ok "02 back legacy (UNPROVISIONED)" || no "02 lock-status after its restore: $(qp 'cat /opt/batdata/state/lock-status')"
}
wait02(){ local t0; t0=$(mono); while [ $(( $(mono) - t0 )) -lt "$1" ]; do [ -n "$(qp 'echo up')" ] && return 0; sleep 15; done; return 1; }
# after a failure: 02 first when it answers; else 04 first (ethernet — its restore may be what brings the mesh back), then 02
recover(){
	if [ "$SNAP02" = 1 ] && [ -n "$(qp 'echo up')" ]; then restore02; pr_abort "fleet join"; return; fi
	if [ "$SNAP02" = 1 ]; then
		say "02 unreachable — restoring 04 first, then retrying 02 for 600 s"
		if pr_restore; then pr_finish_snap; else pr_needs_person "04 restore failed while 02 was unreachable (run $RUN04)"; fi
		if wait02 600; then restore02; else pr_needs_person "02 unreachable after 04 was restored (run $RUN02) — 02 is LOCKED + member with this run's owner key; keys kept in $WSLK"; fi
		pr_release; return
	fi
	pr_abort "fleet join"
}
# any exit: back to 04 first if inside as02; let the library restore 04; then 02, if still claimed, needs a person
fleet_exit(){
	local rc=$?
	[ "$IN02" = 1 ] && { back04; PR_DEADLINE=$G_DL; PR_RESTORING=$G_RS; PR_SNAPPED=$G_SN; IN02=0; }
	pr_on_exit
	[ "$SNAP02" = 1 ] && pr_needs_person "harness exited (rc $rc) with 02 claimed / joined (run $RUN02) — 02 is LOCKED + member with this run's owner key; restore it with prov-base on 02, keys kept in $WSLK"
	return 0
}
pr_begin 3600 || { pr_result; exit 1; }
trap 'fleet_exit' EXIT
if ! fleet; then recover; pr_result; exit 1; fi
restore02 || { pr_result; exit 1; }
pr_end
pr_result

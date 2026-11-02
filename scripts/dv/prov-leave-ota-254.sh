#!/bin/bash
# scripts/dv/prov-leave-ota-254.sh — #254 tier-B unit prov-leave-ota-254 (L22; docs/design/254-h23-harness.md §6.2):
# a node that LEFT its network is not held back by a mesh it no longer belongs to.
#   positive (release helper): claim -> join (random test mesh) -> leave -> the p6 mesh markers (mesh-expected,
#     mesh-joined) are gone, state claimed, and the network is FORGOTTEN (L22, docs/design/254-wireless-txn.md §5):
#     placeholder key (sha prefix), radio1 disabled=1 and in the keyguard mark, no wlh0, prov-state mesh_expect 0,
#     --check rc 0 (p5 holds the placeholder) -> reboot committed -> OTA V into B (hold) -> the B trial is claimed and
#     autocommit says "mesh join required: 0 (prov=claimed mesh_expect=0" -> HELD -> back to A
#   negative control [bind]: restore -> claim -> join -> helper-noleave bound -> leave -> the markers STAY -> reboot ->
#     OTA V (hold) -> "mesh join required: 1" in the trial -> back to A
# Type: hold / A / F. Side effects: 04 off the mesh ~60 min, B rewritten (then rewritten with V again), ~8 reboots.
set -u
PR_UNIT=prov-leave-ota-254
# shellcheck source=scripts/dv/prov-254.sh
. "$(dirname "$0")/prov-254.sh"
MESH="dvl-$(head -c 4 /dev/urandom | od -An -tx1 | tr -d ' \n')"
FD3="umask 077; s=\$(head -c 16 /dev/urandom | hexdump -v -e '1/1 \"%02x\"'); printf 'mesh_id=%s\nchannel=%s\nbw=2\nsae=%s\n' '$MESH' \"\$(uci -q get wireless.radio1.channel)\" \"\$s\""
FORGOT='echo "key=$(@@KEYH@@) dis=$(uci -q get wireless.radio1.disabled) mark=$(grep -qw radio1 /etc/halow-keyguard.blocked 2>/dev/null && echo 1 || echo 0) wlh0=$(iw dev wlh0 info >/dev/null 2>&1 && echo 1 || echo 0) me=$(cut -d" " -f6 /opt/batdata/state/prov-state 2>/dev/null)"'
FORGOT=${FORGOT//@@KEYH@@/"$KEYH"}   # quoted: bash 5.2 patsub_replacement would expand the `&&` of KEYH   # the lib's salted fingerprint (review 4 A m7)
MARK='echo "exp=$([ -e /opt/batdata/state/mesh-expected ] && echo 1 || echo 0) joined=$([ -e /opt/batdata/state/mesh-joined ] && echo 1 || echo 0)"'
# half <negative 0|1>: join, leave, markers, reboot, OTA V, trial judgement, back to A
half(){
	local neg=$1 r i m s b0 want t
	pr_keys && pr_pc_place && pr_claim || return 1
	r=$(pr_pc owner.pem FD3="$FD3" -- net-apply --first "$OWNER"); grep -q "RESULT net.apply code=0 " <<< "$r" || { no "join: $r"; return 1; }
	i=$(pr_info); case " $i " in *" state=member "*) ;; *) no "not member after the join: $i"; return 1 ;; esac
	q 'touch /opt/batdata/state/mesh-expected /opt/batdata/state/mesh-joined; sync'   # as after a real join on the fleet mesh
	if [ "$neg" = 1 ]; then pr_push_helper helper-noleave || return 1; fi
	r=$(pr_pc owner.pem PROVCLIENT_TIMEOUT_S=120 -- leave); echo "    $r"
	grep -q "RESULT network.leave code=0" <<< "$r" || { no "leave: $r"; return 1; }
	i=$(pr_info); m=$(qr "$MARK"); say "after leave: $i $m"
	case " $i " in *" state=claimed "*) ;; *) no "state after leave: $i"; return 1 ;; esac
	if [ "$neg" = 0 ]; then [ "$m" = "exp=0 joined=0" ] && ok "leave removed the mesh markers" || no "markers after leave: $m"
		f=$(qr "$FORGOT"); say "forgotten? $f"
		[ "$f" = "key=$PH dis=1 mark=1 wlh0=0 me=0" ] && ok "leave forgot the network (placeholder, radio1 blocked, no wlh0, mesh_expect 0)" || no "after leave: [$f] (want key=$PH dis=1 mark=1 wlh0=0 me=0)"
		c=$(qr 'batman-config-save --check >/dev/null 2>&1; echo rc=$?'); [ "$c" = rc=0 ] && ok "after leave: --check rc 0 (p5 holds the placeholder)" || no "after leave: --check $c"
	else [ "$m" = "exp=1 joined=1" ] && ok "negative control: helper-noleave leaves the markers ($m)" || { no "negative control: the markers went anyway ($m) — the mutant had no effect"; return 1; }; fi
	s=$(qr "$ST"); b0=$(field "$s" boot)
	q "(batman-slot reboot committed prov-dv-254 </dev/null >/dev/null 2>&1 &)"
	pr_find 900 "$b0" || return 1
	pr_ota_b "$PR_V" B || return 1
	want="mesh join required: 0 (prov=claimed mesh_expect=0"; [ "$neg" = 1 ] && want="mesh join required: 1 "
	t=0; while [ $t -lt 30 ]; do r=$(qr "logread | grep -m1 'mesh join required:'"); [ -n "$r" ] && break; sleep 10; t=$((t + 1)); done
	say "trial: ${r##*autocommit}"
	if [ "$neg" = 0 ]; then
		grep -qF "$want" <<< "$r" && ok "B trial: $want" || no "B trial wants [$want], has [$r]"
		pr_wait_held 480 && ok "B trial HELD (no mesh needed after leave)" || no "B trial not HELD by uptime 480 s"
	else
		grep -qF "$want" <<< "$r" && ok "negative control: the B trial still requires the mesh ($want)" || no "negative control: [$r] (want $want)"
	fi
	back_to_a || return 1
	return 0
}
pr_begin 3000 || { pr_result; exit 1; }
half 0 || { pr_abort "positive half"; pr_result; exit 1; }
pr_restore || { pr_abort "restore between the halves"; pr_result; exit 1; }
if ! qr '/usr/bin/batman-provhelper --version >/dev/null 2>&1'; then
	no "pre-P1b image: $(field "$(qr "$ST")" ver) (helper has no --version) — the helper-noleave negative control needs P1b"
else
	half 1 || { pr_abort "negative half"; pr_result; exit 1; }
fi
pr_end
pr_result

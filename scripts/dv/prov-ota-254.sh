#!/bin/bash
# scripts/dv/prov-ota-254.sh — #254 tier-B unit prov-ota-254 (L5) + autocommit (3) (docs/design/254-h23-harness.md
# §6.2): a MEMBER's OTA carries its provisioning into the new slot.
#   positive: member (random test mesh, never JOINED) -> reboot committed -> OTA V into B (hold) -> in the B trial:
#     autocommit "member: armed in radio-only mode (ota-armed.mesh)" + "mesh join required: 0 (prov=member";
#     the helper says member, same generation; wireless == A's; locked; /etc/.batman-prov-restore "prov=full";
#     96 "prov: state=member copied=full"; /rom = the payload's squashfs (E-H5 #4); HELD -> back to A
#   negative control [wbox-B]: the same with -wbox 96-noprov (96 copies no provisioning) -> "copied=none"
# Type: hold / A / F. Side effects: 04 off the mesh ~70 min, B rewritten (wbox, then V again), ~9 reboots.
set -u
PR_UNIT=prov-ota-254
# shellcheck source=scripts/dv/prov-254.sh
. "$(dirname "$0")/prov-254.sh"
NL='
'
WSUM='printf "%s|%s|%s" "$(uci -q get wireless.default_radio1.mesh_id)" "$(uci -q get wireless.radio1.channel)" "$(uci -q get wireless.default_radio1.key | sha256sum | cut -c1-16)"'
half(){	# <payload version> <negative 0|1>
	local v=$1 neg=$2 w0 w1 r i l
	pr_member || return 1
	w0=$(qr "$WSUM")
	pr_ota_b "$v" B || return 1
	l=$(qr "logread | grep -m1 'prov: state=' ; cat /etc/.batman-prov-restore 2>/dev/null | cut -d' ' -f2-")
	say "B trial 96: $(echo $l)"
	if [ "$neg" = 1 ]; then
		grep -q 'copied=none' <<< "$l" && ok "negative control: 96-noprov -> copied=none" || no "negative control: 96-noprov did not drop the copy ($l) — the mutant had no effect"
		back_to_a; return 0
	fi
	grep -q 'prov: state=member copied=full' <<< "$l" && ok "96: prov: state=member copied=full" || no "96 line: $l"
	# E-H5 #4 (254-h23 §22.6): in the B trial /rom is the payload's squashfs, read-only, and names the payload version —
	# the wbox gate and the protected-set checks read /rom/etc/batman-build (§19.3); A committed was checked 2026-10-28
	r=$(qr "grep ' /rom ' /proc/mounts; sed -n 's/^BATMAN_VERSION=//p' /rom/etc/batman-build")
	case "$r" in *" /rom squashfs ro"*"$NL$v") ok "E-H5 #4: B trial /rom = squashfs ro, BATMAN_VERSION=$v" ;; *) no "E-H5 #4: B trial /rom [$(echo $r)] (want squashfs ro + $v)" ;; esac
	grep -q 'prov=full' <<< "$l" && ok ".batman-prov-restore prov=full" || no ".batman-prov-restore: $l"
	r=$(pr_trial_line 'member: armed in radio-only mode') && ok "autocommit: ${r##*autocommit*: }" || no "no 'member: armed in radio-only mode' line in the B trial"
	r=$(pr_trial_line 'mesh join required:') ; case "$r" in *"mesh join required: 0 (prov=member"*) ok "autocommit: mesh join required: 0 (prov=member …)";; *) no "B trial: [$r] (want mesh join required: 0 (prov=member)";; esac
	pr_pc_place || return 1
	i=$(pr_info); case " $i " in *" state=member gen=$PR_MEMBER_GEN "*) ok "B trial: member, gen $PR_MEMBER_GEN unchanged";; *) no "B trial helper state: $i (want member gen $PR_MEMBER_GEN)";; esac
	w1=$(qr "$WSUM"); [ "$w1" = "$w0" ] && ok "B trial: wireless == A's (mesh_id, channel, key hash)" || no "B trial wireless [$w1] != A's [$w0]"
	l=$(qr 'cat /opt/batdata/state/lock-status'); [ "$l" = LOCKED ] && ok "B trial: LOCKED" || no "B trial lock-status [$l]"
	pr_wait_held 480 && ok "B trial HELD" || no "B trial not HELD by uptime 480 s"
	back_to_a || return 1
	return 0
}
pr_begin 3000 || { pr_result; exit 1; }
half "$PR_V" 0 || { pr_abort "positive half"; pr_result; exit 1; }
pr_restore || { pr_abort "restore between the halves"; pr_result; exit 1; }
half "$PR_V.dirty.wbox-96-noprov" 1 || { pr_abort "negative half"; pr_result; exit 1; }
pr_end
pr_result

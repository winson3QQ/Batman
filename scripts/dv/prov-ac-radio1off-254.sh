#!/bin/bash
# scripts/dv/prov-ac-radio1off-254.sh — #254 tier-B unit autocommit (1) (docs/design/254-h23-harness.md §6.2, F12):
# a trial whose HaLow radio is off is reverted even while held (the hold blocks a commit, never a revert).
#   -wbox radio1-off into B (hold; 99zz-wbox-radio1-off sets radio1.disabled=1) -> the trial cannot join the mesh 04
#   expects (S0 has mesh-expected) -> TRIAL-REVERTED within the trial's deadline + DEFER_MAX + 120 s, its reason naming
#   "mesh not joined/reachable" or "member: HaLow mesh interface not up"; HELD instead = the mutant had no effect ->
#   FAIL + back to A; a hard reboot without TRIAL-REVERTED = INVALID (trial panic). Then bad-slot (slot=B version=<wbox>)
#   is checked and removed before the restore.
# Type: hold+revert / A. Side effects: 04 ~45 min off the mesh, B rewritten (wbox, then V), 4 reboots.
set -u
PR_UNIT=prov-ac-radio1off-254
# shellcheck source=scripts/dv/prov-254.sh
. "$(dirname "$0")/prov-254.sh"
pr_begin 3000 || { pr_result; exit 1; }
[ -n "$(qr 'ls /opt/batdata/state/mesh-expected /opt/batdata/state/mesh-joined 2>/dev/null')" ] \
	|| { pr_abort "precondition: 04 expects no mesh (no mesh-expected / mesh-joined) — the radio-off trial would not need one"; pr_result; exit 1; }
pr_ota_b "$PR_V.dirty.wbox-radio1-off" B || { pr_abort "OTA radio1-off"; pr_result; exit 1; }
r=$(qr 'uci -q get wireless.radio1.disabled'); [ "$r" = 1 ] && ok "B trial: radio1.disabled=1 (the mutant is in effect)" || no "B trial radio1.disabled=[$r]"
if pr_wait_reverted; then
	r=$(qr "grep 'TRIAL-REVERTED' /opt/batdata/log/autocommit.log | tail -1")
	case "$r" in *"mesh not joined/reachable"*|*"member: HaLow mesh interface not up"*) ok "revert reason names the mesh: ${r##*reason=}";; *) no "revert reason: [$r]";; esac
	pr_end revert
else
	[ "$(field "$(qr "$ST")" slot)" = B ] && back_to_a
	pr_abort "no TRIAL-REVERTED"
fi
pr_result

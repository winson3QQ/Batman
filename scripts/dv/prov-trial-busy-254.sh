#!/bin/bash
# scripts/dv/prov-trial-busy-254.sh — #254 tier-B unit prov-trial-busy-254 (L21; docs/design/254-h23-harness.md §6.2):
# while a slot is on trial, no state-changing verb is accepted (it would write p5 from a slot that may be reverted).
#   positive: OTA V into B (hold) -> in the B trial, claim -> E_BUSY (7) "trial slot (updating)"; the state unchanged
#   negative control [bind in the B trial + restart]: helper-notrial (ignores IsTrial) -> the same claim is ACCEPTED
# Type: hold / A / F. Side effects: 04 ~45 min (two trials), B rewritten with V twice, p5 restored at the end.
set -u
PR_UNIT=prov-trial-busy-254
# shellcheck source=scripts/dv/prov-254.sh
. "$(dirname "$0")/prov-254.sh"
pr_begin 3000 || { pr_result; exit 1; }
pr_keys || { pr_abort keys; pr_result; exit 1; }
pr_ota_b "$PR_V" B || { pr_abort "OTA (positive)"; pr_result; exit 1; }
pr_pc_place && pk_proof || { pr_abort "place / pk_proof in the trial"; pr_result; exit 1; }
i0=$(pr_info); r=$(pr_pc owner.pem -- claim "$OWNER" "$ENC"); echo "    $r"
grep -q "RESULT claim.verify code=7 " <<< "$r" && ok "B trial: claim -> E_BUSY (7)" || no "B trial claim: [$r] (want code=7)"
i1=$(pr_info); [ "$i1" = "$i0" ] && ok "B trial: state unchanged ($i1)" || no "B trial state changed: [$i0] -> [$i1]"
back_to_a || { pr_abort "back to A"; pr_result; exit 1; }
if ! qr '/usr/bin/batman-provhelper --version >/dev/null 2>&1'; then
	no "pre-P1b image: $(field "$(qr "$ST")" ver) (helper has no --version) — the helper-notrial negative control needs P1b"
else
	pr_ota_b "$PR_V" B || { pr_abort "OTA (negative)"; pr_result; exit 1; }
	pr_pc_place && pk_proof && pr_push_helper helper-notrial || { pr_abort "helper-notrial in the trial"; pr_result; exit 1; }
	r=$(pr_pc owner.pem -- claim "$OWNER" "$ENC"); echo "    $r"
	grep -q "RESULT claim.verify code=0 " <<< "$r" && ok "negative control: helper-notrial accepts the claim in the trial" || no "negative control: [$r] (want code=0) — the mutant had no effect"
	back_to_a || { pr_abort "back to A (negative)"; pr_result; exit 1; }
fi
pr_end
pr_result

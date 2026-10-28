#!/bin/bash
# scripts/dv/prov-claim-kp-254.sh — #254 tier-B unit, the parts of prov-claim-254 that need the P1b seams (docs/design/
# 254-h23-harness.md §6.2; the claim-lock unit scripts/dv/prov-claim-254.sh keeps the rest):
#   1 power lost after the claim is in p5 but not in the overlay (killpoint claim-after-persist): sysrq -> the helper
#     rebuilds the claimed record from p5 -> claim.replay works twice with the same owner_tag_key (the persisted one)
#   2 an empty /etc/dropbear/authorized_keys (bound in place for the claim only): the claim is refused (it would lock
#     the operator out), the node stays legacy
#   3 negative control [bind]: helper-clientchal (takes the client's ClientChal) -> the attacker's response, refused by
#     the release helper (code 3), is ACCEPTED
# Type: — / A / F. Side effects: 04 ~45 min, one sysrq reboot, claimed twice, restored.
set -u
PR_UNIT=prov-claim-kp-254
# shellcheck source=scripts/dv/prov-254.sh
. "$(dirname "$0")/prov-254.sh"
pr_begin 3000 || { pr_result; exit 1; }
if ! qr '/usr/bin/batman-provhelper --version >/dev/null 2>&1'; then no "pre-P1b image: $(field "$(qr "$ST")" ver) — needs a P1b rc"; pr_end; pr_result; exit 1; fi
pr_keys && pr_pc_place && pk_proof || { pr_abort "keys"; pr_result; exit 1; }
# ---- 2 (first, the node still legacy): an empty authorized_keys refuses the claim
pw prep >/dev/null; q ": > /tmp/run/batman-dv/wbox/$RUN/empty.keys"
h=$(qr "sha256sum < /tmp/run/batman-dv/wbox/$RUN/empty.keys | cut -c1-64")
o=$(pw bind empty.keys "$h" /etc/dropbear/authorized_keys); say "$o"
r=$(pr_pc owner.pem -- claim "$OWNER" "$ENC"); u=$(pw unbind-all); echo "    $r"; say "unbind: $(echo $u)"
grep -q "RESULT claim.verify code=0 " <<< "$r" && no "a claim with an empty authorized_keys was accepted (locks the operator out)" || ok "empty authorized_keys: claim refused ($(echo $r | sed 's/.*code=\([0-9]*\).*/code \1/'))"
i=$(pr_info); case " $i " in *" state=legacy "*) ok "still legacy after the refused claim";; *) no "state after the refused claim: $i";; esac
# ---- 1 the claim cut at claim-after-persist
PR_FD3=""; pr_killpoint claim-after-persist claim "$OWNER" "$ENC" || { pr_abort "killpoint claim-after-persist"; pr_result; exit 1; }
l=$(qr "logread | grep 'batman-provhelper' | grep -E 'boot rc=' | tail -1"); say "boot: $l"
grep -q 'verdict=claimed' <<< "$l" && ok "the helper came back claimed ($l)" || no "boot verdict after the cut claim: $l"
r1=$(pr_pc owner.pem -- replay "$OWNER"); r2=$(pr_pc owner.pem -- replay "$OWNER"); echo "    $r1"; echo "    $r2"
t1=$(sed -n 's/.*code=0 tag=\([0-9a-f]*\).*/\1/p' <<< "$r1"); t2=$(sed -n 's/.*code=0 tag=\([0-9a-f]*\).*/\1/p' <<< "$r2")
[ -n "$t1" ] && [ "$t1" = "$t2" ] && ok "claim.replay works after the cut, owner_tag_key stable ($t1)" || no "replay after the cut: [$r1] [$r2]"
pr_restore || { pr_abort "restore"; pr_result; exit 1; }
# ---- 3 negative control: helper-clientchal accepts the attacker's response
pr_pc_place && pr_push_helper helper-clientchal || { pr_abort "helper-clientchal"; pr_result; exit 1; }
r=$(pr_pc owner.pem -- claim-attacker "$ATK" "$ENC" "$OWNER"); echo "    $r"
grep -q "RESULT claim.verify code=0 " <<< "$r" && ok "negative control: helper-clientchal accepts the attacker's response" || no "negative control: [$r] (want code=0) — the mutant had no effect"
pr_end
pr_result
